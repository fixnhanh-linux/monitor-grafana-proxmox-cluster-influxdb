package PVE::CustomNetworkMetrics;

use strict;
use warnings;

# Bộ đếm trong /sys/class/net/<if>/statistics (tương đương 'ip -s link')
my @SYSFS_COUNTERS = qw(
    rx_bytes rx_packets tx_bytes tx_packets
    rx_errors rx_dropped rx_missed_errors rx_over_errors rx_fifo_errors
    rx_frame_errors rx_crc_errors rx_length_errors rx_nohandler multicast
    tx_errors tx_dropped tx_carrier_errors tx_aborted_errors tx_fifo_errors
    tx_heartbeat_errors tx_window_errors collisions
);

# Chỉ giữ counter của 'ethtool -S' liên quan tới lỗi/rớt gói
my $ETHTOOL_KEEP = qr/err|drop|discard|crc|miss|timeout|length|fifo|over|collision|carrier|illegal|jabber|fragment|undersize|oversize/i;
# Bỏ counter theo từng queue để tránh phình số series
my $ETHTOOL_SKIP = qr/queue|^[rt]x[-_]?\d+[._]|\[\d+\]|_q\d+/i;

my $ETHTOOL = -x '/usr/sbin/ethtool' ? '/usr/sbin/ethtool' : 'ethtool';

sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    my $v = <$fh>;
    close($fh);
    chomp($v) if defined($v);
    return $v;
}

sub get_ethtool_stats {
    my ($iface) = @_;
    my $stats = {};

    open(my $fh, '-|', '/usr/bin/timeout', '2', $ETHTOOL, '-S', $iface) or return $stats;
    while (my $line = <$fh>) {
        next if $line !~ /^\s*(\S.*?):\s*(\d+)\s*$/;
        my ($name, $val) = ($1, $2);
        next if $name !~ $ETHTOOL_KEEP || $name =~ $ETHTOOL_SKIP;
        $name = lc($name);
        $name =~ s/[^a-z0-9]+/_/g;
        $name =~ s/^_|_$//g;
        $stats->{"ethtool_$name"} = $val + 0;
    }
    close($fh);

    return $stats;
}

# Tốc độ tối đa card hỗ trợ (Mb/s). pvestatd chạy liên tục nên giá trị được nhớ giữa các chu kỳ,
# card đang DOWN vẫn biết là card 10G/25G.
my %MAX_SPEED;

sub get_max_speed {
    my ($iface, $cur) = @_;

    if (!$MAX_SPEED{$iface}) {
        my $max = 0;
        if (open(my $fh, '-|', '/usr/bin/timeout', '2', $ETHTOOL, $iface)) {
            local $/;
            my $out = <$fh> // '';
            close($fh);
            if ($out =~ /Supported link modes:(.*?)\n\s*\S[^\n:]*:/s) {
                foreach my $m ($1 =~ /(\d+)base/g) {
                    $max = $m if $m > $max;
                }
            }
        }
        $MAX_SPEED{$iface} = $max if $max > 0;
    }

    # Driver không báo link mode: dùng tốc độ cao nhất từng thấy
    $MAX_SPEED{$iface} = $cur if $cur > ($MAX_SPEED{$iface} // 0);

    return $MAX_SPEED{$iface} // 0;
}

# Phân tích output 'corosync-cfgtool -s', trả về { <link id> => { addr, peers, connected } }.
# Hỗ trợ cả định dạng mới ("nodeid: 2: connected") và cũ ("nodeid 2: link enabled:1 link connected:1").
sub parse_corosync_status {
    my ($text) = @_;
    my (%links, $id, $local);

    foreach my $line (split(/\n/, $text // '')) {
        if ($line =~ /^Local node ID (\d+)/) {
            $local = $1;
        } elsif ($line =~ /^LINK ID (\d+)/) {
            $id = $1;
            $links{$id} = { addr => '', peers => 0, connected => 0 };
        } elsif (defined($id) && $line =~ /^\s*addr\s*=\s*(\S+)/) {
            $links{$id}->{addr} = $1;
        } elsif (defined($id) && $line =~ /nodeid:?\s+(\d+):\s*(.*)$/) {
            my ($node, $st) = ($1, $2);
            next if $st =~ /localhost/ || (defined($local) && $node == $local);
            $links{$id}->{peers}++;
            $links{$id}->{connected}++
                if $st =~ /\bconnected\b/ && $st !~ /disconnected/ && $st !~ /connected:\s*0/;
        }
    }

    return \%links;
}

# Tên card mạng đang giữ một địa chỉ IP (để biết link corosync chạy qua card nào)
sub iface_of_addr {
    my ($addr) = @_;
    return '' if !$addr;
    foreach my $line (split(/\n/, `ip -o addr show 2>/dev/null`)) {
        return $1 if $line =~ /^\d+:\s+(\S+?)(?:\@\S+)?\s+inet6?\s+\Q$addr\E\//;
    }
    return '';
}

our $SYSNET = '/sys/class/net';

# Card vật lý nằm dưới một interface: đi xuống qua lower_* (vlan -> bond/bridge -> card)
sub physical_nics {
    my ($iface, $depth) = @_;
    $depth //= 0;
    return () if !$iface || $depth > 5 || !-e "$SYSNET/$iface";
    return ($iface) if -e "$SYSNET/$iface/device";

    my %seen;
    foreach my $lower (glob("$SYSNET/$iface/lower_*")) {
        (my $name = $lower) =~ s#.*/lower_##;
        $seen{$_} = 1 foreach physical_nics($name, $depth + 1);
    }
    return sort keys %seen;
}

# Tốc độ cao nhất (Mb/s) trong các card đang UP; 0 nếu không đọc được
sub nics_speed {
    my $max = 0;
    foreach my $nic (@_) {
        my $op = read_file("$SYSNET/$nic/operstate") // '';
        next if $op ne 'up';
        my $sp = read_file("$SYSNET/$nic/speed");
        $max = $sp if defined($sp) && $sp =~ /^\d+$/ && $sp < 1000000 && $sp > $max;
    }
    return $max + 0;
}

# Số liệu từng link corosync: số node kết nối được, link UP khi kết nối được tới mọi node
sub get_corosync_links {
    my $global = {};
    return $global if !-x '/usr/sbin/corosync-cfgtool';

    my $out = '';
    if (open(my $fh, '-|', '/usr/bin/timeout', '2', '/usr/sbin/corosync-cfgtool', '-s')) {
        local $/;
        $out = <$fh> // '';
        close($fh);
    }
    my $links = parse_corosync_status($out);
    return $global if !%$links;

    my $up = 0;
    foreach my $id (sort { $a <=> $b } keys %$links) {
        my $l = $links->{$id};
        my $link_up = ($l->{peers} > 0 && $l->{connected} == $l->{peers}) ? 1 : 0;
        $up += $link_up;
        $global->{"corosync_link${id}_peers"} = $l->{peers};
        $global->{"corosync_link${id}_connected"} = $l->{connected};
        $global->{"corosync_link${id}_up"} = $link_up;
        $global->{"corosync_link${id}_addr"} = $l->{addr} if $l->{addr} ne '';
        my $iface = iface_of_addr($l->{addr});
        next if $iface eq '';
        $global->{"corosync_link${id}_iface"} = $iface;
        # Card vật lý thật bên dưới (vd vlan3001 -> ens3f0np0+ens3f1np1) và tốc độ, để biết link chạy 10G hay 1G
        my @nics = physical_nics($iface);
        if (@nics) {
            $global->{"corosync_link${id}_nics"} = join('+', @nics);
            $global->{"corosync_link${id}_speed"} = nics_speed(@nics);
        }
    }
    $global->{corosync_links} = scalar(keys %$links);
    $global->{corosync_links_up} = $up;

    return $global;
}

# Hàm này sẽ được gọi từ PVE::Status::InfluxDB
sub get_metrics {

    my $result = {
        global => {},
        nics => {}
    };

    eval {
        # 1. Thu thập dữ liệu hệ thống (UDP/Corosync)
        my $udp_loss = `awk '/Udp:/ {print \$4}' /proc/net/snmp | tail -n 1`; chomp($udp_loss);
        my $udp_total = `awk '/Udp:/ {print \$2}' /proc/net/snmp | tail -n 1`; chomp($udp_total);
        my $corosync = `ss -una | grep -E '5404|5405' | wc -l`; chomp($corosync);

        $result->{global}->{udp_loss} = $udp_loss + 0;
        $result->{global}->{udp_total} = $udp_total + 0;
        $result->{global}->{corosync_conn} = $corosync + 0;

        # Trạng thái từng link corosync (link0, link1...) từ corosync-cfgtool -s
        my $cs = get_corosync_links();
        $result->{global}->{$_} = $cs->{$_} foreach keys %$cs;

        # 2. Quét các card mạng
        foreach my $iface (glob("/sys/class/net/*")) {
            $iface =~ s#.*/##;
            next if $iface eq 'lo';
            my $dir = "/sys/class/net/$iface";

            # HW Drop (giữ tên cũ cho panel hiện có)
            my $drop = read_file("$dir/statistics/rx_dropped");
            if (defined($drop) && $drop =~ /^\d+$/) {
                $result->{nics}->{$iface}->{hardware_drop} = $drop + 0;
            }

            # Trạng thái UP/DOWN
            my $operstate = read_file("$dir/operstate");
            if (defined($operstate) && $operstate ne '') {
                $result->{nics}->{$iface}->{network_up} = ($operstate eq 'up' || $operstate eq 'unknown') ? 1 : 0;
            }

            # Card ảo của VM/firewall: không lấy bộ đếm lỗi
            next if $iface =~ /^(tap|veth|fwbr|fwpr|fwln)/;

            # 3. Bộ đếm lỗi/rớt gói của kernel (ip -s link)
            foreach my $c (@SYSFS_COUNTERS) {
                my $v = read_file("$dir/statistics/$c");
                $result->{nics}->{$iface}->{$c} = $v + 0 if defined($v) && $v =~ /^\d+$/;
            }

            if (-e "$dir/device") {
                # 4. Tốc độ link hiện tại (0 = DOWN) và tốc độ tối đa của card, đơn vị Mb/s
                my $speed = read_file("$dir/speed");
                $speed = (defined($speed) && $speed =~ /^\d+$/ && $result->{nics}->{$iface}->{network_up}) ? $speed + 0 : 0;
                $speed = 0 if $speed > 1000000; # một số driver trả 65535/4294967295 khi chưa có link
                $result->{nics}->{$iface}->{link_speed} = $speed;
                $result->{nics}->{$iface}->{link_speed_max} = get_max_speed($iface, $speed);

                # 5. Counter của driver (ethtool -S), chỉ với card vật lý
                my $es = get_ethtool_stats($iface);
                $result->{nics}->{$iface}->{$_} = $es->{$_} foreach keys %$es;
            }
        }
    };
    if (my $err = $@) {
        warn "Loi khi thu thap advanced network metrics: $err\n";
    }

    return $result;
}

1;
