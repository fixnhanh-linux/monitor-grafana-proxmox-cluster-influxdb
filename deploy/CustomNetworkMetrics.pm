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
