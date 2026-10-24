#!/bin/bash
# deploy-monitor-nic-proxmox.sh - Trien khai Monitor card mang (NIC) Proxmox
# Thu thap loi/rot goi (ip -s link + ethtool -S) va UP/DOWN card 10G qua pvestatd -> InfluxDB
#
# Cach dung:
#   ./deploy-monitor-nic-proxmox.sh install   10.0.0.11 10.0.0.12 ...
#   ./deploy-monitor-nic-proxmox.sh install   -f nodes.txt
#   ./deploy-monitor-nic-proxmox.sh check     -f nodes.txt
#   ./deploy-monitor-nic-proxmox.sh uninstall -f nodes.txt
#   ./deploy-monitor-nic-proxmox.sh check                  (khong truyen gi = dung nodes.txt canh script)
#   ./deploy-monitor-nic-proxmox.sh diag      -f nodes.txt (chan doan: du lieu da vao InfluxDB chua, loi o dau)
#   ./deploy-monitor-nic-proxmox.sh dashboard [bucket]     (tao dashboard Grafana dung bucket cua cluster)
#
# Mac dinh dang nhap bang SSH key. Neu can mat khau: export SSH_PASS='...' (phai co sshpass).
# Doi user SSH: export SSH_USER=root (mac dinh root).
# Lenh dashboard: bucket lay tu /etc/pve/status.cfg neu khong truyen. Bien tuy chon:
#   GRAFANA_DS='ten datasource'  GRAFANA_URL=https://ip:3000  GRAFANA_TOKEN='glsa_...'  (co URL+TOKEN thi import luon)

set -u

PM_NAME="CustomNetworkMetrics.pm"
TARGET="/usr/share/perl5/PVE/CustomNetworkMetrics.pm"
INFLUX="/usr/share/perl5/PVE/Status/InfluxDB.pm"
STATUS_CFG="${STATUS_CFG:-/etc/pve/status.cfg}"
METRIC_PRIV="${METRIC_PRIV:-/etc/pve/priv/metricserver}"

# ======================================================================
# Phan chay tren node Proxmox (duoc goi qua: ssh node "bash -s -- --remote <action>" < deploy-monitor-nic-proxmox.sh)
# ======================================================================

remote_patch_influx() {
    local tmp
    tmp=$(mktemp)

    cat > "$tmp.pl" << 'PERL'
local $/;
my $s = <STDIN>;

unless ($s =~ /^use PVE::CustomNetworkMetrics;/m) {
    $s =~ s/^(use PVE::Status::Plugin;\n)/$1use PVE::CustomNetworkMetrics;\n/m
        or die "khong thay dong 'use PVE::Status::Plugin;'\n";
}

unless ($s =~ /PVE::CustomNetworkMetrics::get_metrics/) {
    my $block = <<'BLK';
    # --- BEGIN CustomNetworkMetrics ---
    my $extra_metrics = PVE::CustomNetworkMetrics::get_metrics();
    if ($extra_metrics) {
        foreach my $k (keys %{ $extra_metrics->{global} || {} }) {
            $data->{$k} = $extra_metrics->{global}->{$k};
        }
        foreach my $nic (keys %{ $extra_metrics->{nics} || {} }) {
            foreach my $k (keys %{ $extra_metrics->{nics}->{$nic} }) {
                $data->{nics}->{$nic}->{$k} = $extra_metrics->{nics}->{$nic}->{$k};
            }
        }
    }
    # --- END CustomNetworkMetrics ---

BLK
    $s =~ s/^(?=[ \t]*build_influxdb_payload\(\$class, \$txn, \$data, \$ctime, "object=nodes)/$block/m
        or die "khong thay diem chen trong update_node_status\n";
}

print $s;
PERL

    if ! perl "$tmp.pl" < "$INFLUX" > "$tmp"; then
        rm -f "$tmp" "$tmp.pl"
        return 1
    fi
    if ! perl -I/usr/share/perl5 -c "$tmp" > /dev/null 2>&1; then
        echo "  [LOI] InfluxDB.pm sau khi patch bi loi cu phap, khong ghi de:"
        perl -I/usr/share/perl5 -c "$tmp" 2>&1 | sed 's/^/    /'
        rm -f "$tmp" "$tmp.pl"
        return 1
    fi
    # Ghi de noi dung, giu nguyen quyen/owner cua file goc
    cat "$tmp" > "$INFLUX"
    rm -f "$tmp" "$tmp.pl"
}

remote_check() {
    local ok=0

    [ -f "$TARGET" ] && echo "  [OK] Co $TARGET" || { echo "  [THIEU] $TARGET"; ok=1; }

    if grep -q 'PVE::CustomNetworkMetrics::get_metrics' "$INFLUX" 2>/dev/null; then
        echo "  [OK] InfluxDB.pm da duoc patch"
    else
        echo "  [THIEU] InfluxDB.pm chua patch (co the do vua nang cap pve-manager)"
        ok=1
    fi

    command -v ethtool > /dev/null && echo "  [OK] Co ethtool" || echo "  [CANH BAO] Khong co ethtool -> khong co counter ethtool_*"

    if systemctl is-active --quiet pvestatd; then
        echo "  [OK] pvestatd dang chay"
    else
        echo "  [LOI] pvestatd khong chay"
        ok=1
    fi

    if [ -f "$TARGET" ]; then
        # Chay thu module, in so field lay duoc cho tung card vat ly
        perl -I/usr/share/perl5 -MPVE::CustomNetworkMetrics -e '
            my $m = PVE::CustomNetworkMetrics::get_metrics();
            printf "  udp_loss=%s corosync_conn=%s\n", $m->{global}{udp_loss} // "-", $m->{global}{corosync_conn} // "-";
            foreach my $if (sort keys %{ $m->{nics} }) {
                next unless -e "/sys/class/net/$if/device";
                my $n = $m->{nics}{$if};
                my @eth = grep { /^ethtool_/ } keys %$n;
                my $state = $n->{network_up} ? "UP" : "DOWN";
                printf "  %-16s %-4s %6s/%-6s rx_errors=%s rx_dropped=%s tx_dropped=%s rx_crc=%s (+%d counter ethtool)\n",
                    $if, $state, $n->{link_speed} // "-", $n->{link_speed_max} // "-",
                    map({ $n->{$_} // "-" } qw(rx_errors rx_dropped tx_dropped rx_crc_errors)), scalar(@eth);
            }' || ok=1
    fi

    return $ok
}

remote_install() {
    if [ ! -f "$INFLUX" ]; then
        echo "  [LOI] Khong thay $INFLUX, day khong phai node Proxmox?"
        return 1
    fi
    if ! perl -c "/tmp/$PM_NAME" > /dev/null 2>&1; then
        echo "  [LOI] /tmp/$PM_NAME khong hop le"
        return 1
    fi

    install -m 0644 "/tmp/$PM_NAME" "$TARGET"
    rm -f "/tmp/$PM_NAME"
    echo "  [OK] Da cai $TARGET"

    # Backup ban goc 1 lan duy nhat, khong ghi de ban backup sach
    cp -n "$INFLUX" "$INFLUX.bak"

    if grep -q 'PVE::CustomNetworkMetrics::get_metrics' "$INFLUX"; then
        echo "  [OK] InfluxDB.pm da duoc patch tu truoc, bo qua"
    else
        remote_patch_influx || return 1
        echo "  [OK] Da patch InfluxDB.pm (backup: $INFLUX.bak)"
    fi

    systemctl restart pvestatd
    sleep 2
    remote_check
}

remote_uninstall() {
    local pkg
    pkg=$(dpkg -S "$INFLUX" 2>/dev/null | cut -d: -f1)

    # Cai lai package de lay InfluxDB.pm goc dung voi phien ban hien tai
    if [ -n "$pkg" ] && apt-get install -y --reinstall "$pkg" > /dev/null 2>&1; then
        echo "  [OK] Da khoi phuc InfluxDB.pm bang cach reinstall $pkg"
    elif [ -f "$INFLUX.bak" ]; then
        cp "$INFLUX.bak" "$INFLUX"
        echo "  [OK] Da khoi phuc InfluxDB.pm tu $INFLUX.bak"
    else
        echo "  [LOI] Khong khoi phuc duoc InfluxDB.pm (khong reinstall duoc va khong co .bak)"
        return 1
    fi

    if grep -q 'CustomNetworkMetrics' "$INFLUX"; then
        echo "  [LOI] InfluxDB.pm van con tham chieu CustomNetworkMetrics, giu lai module"
        return 1
    fi

    rm -f "$TARGET"
    systemctl restart pvestatd
    echo "  [OK] Da go module va restart pvestatd"
}

# Doc 1 gia tri cua metric server influxdb dau tien trong status.cfg ("id" = ten metric server)
influx_cfg() {
    awk -v k="$1" '
        /^influxdb:/ { s = 1; if (k == "id") { print $2; exit } next }
        /^[a-z]+:/   { s = 0 }
        s && $1 == k { print $2; exit }' "$STATUS_CFG" 2>/dev/null
}

# Dem so dong du lieu trong CSV tra ve tu InfluxDB (bo header, dong trong)
influx_rows() {
    tr -d '\r' | awk -F, 'NF > 1 && $2 != "result" && $1 !~ /^#/ { n++ } END { print n + 0 }'
}

# In cot instance / _field / _value tu CSV tra ve tu InfluxDB
influx_print_nics() {
    tr -d '\r' | awk -F, '
        $2 == "result" { for (i = 1; i <= NF; i++) col[$i] = i; next }
        NF > 1 && $1 !~ /^#/ { printf "      %-16s %-16s %s\n", $col["instance"], $col["_field"], $col["_value"] }'
}

remote_diag() {
    local h id server port bucket org proto timeout prefix disable base token log health
    local n_sys n_nic auth_err=0 net_err=0
    h=$(hostname)

    echo "  --- 1. Module va patch tren node ---"
    [ -f "$TARGET" ] && echo "  [OK] Co module $TARGET" || echo "  [THIEU] Chua cai module, chay: install"
    grep -q 'PVE::CustomNetworkMetrics::get_metrics' "$INFLUX" 2>/dev/null \
        && echo "  [OK] InfluxDB.pm da patch" || echo "  [THIEU] InfluxDB.pm chua patch, chay: install"
    systemctl is-active --quiet pvestatd && echo "  [OK] pvestatd dang chay" || echo "  [LOI] pvestatd khong chay"

    echo "  --- 2. Cau hinh Metric Server (/etc/pve/status.cfg) ---"
    id=$(influx_cfg id)
    if [ -z "$id" ]; then
        echo "  [LOI] Khong co metric server InfluxDB. Them trong Datacenter -> Metric Server -> Add -> InfluxDB"
        return 1
    fi
    server=$(influx_cfg server); port=$(influx_cfg port); bucket=$(influx_cfg bucket)
    org=$(influx_cfg organization); proto=$(influx_cfg influxdbproto); timeout=$(influx_cfg timeout)
    prefix=$(influx_cfg api-path-prefix); disable=$(influx_cfg disable)
    proto=${proto:-udp}
    echo "  Metric server '$id': $proto://$server:${port:-?} org=${org:--} bucket=${bucket:--} timeout=${timeout:-mac dinh}"
    [ "$disable" = "1" ] && echo "  [LOI] Metric server '$id' dang bi TAT (disable 1). Bat lai trong Datacenter -> Metric Server"
    if [ -n "$timeout" ] && [ "$timeout" -lt 10 ] 2>/dev/null; then
        echo "  [CANH BAO] timeout=$timeout giay la ngan, de mat du lieu khi gui qua Internet."
        echo "             Tang len: pvesh set /cluster/metrics/server/$id --server $server --port $port --timeout 30"
        echo "             (hoac Datacenter -> Metric Server -> $id -> Edit), roi: systemctl restart pvestatd"
    fi

    echo "  --- 3. Log pvestatd 15 phut gan nhat ---"
    log=$(journalctl -u pvestatd --since "-15 min" --no-pager 2>/dev/null \
        | grep -iE 'influx|metric|send|timeout|error|fail|Loi khi thu thap' | tail -8)
    if [ -z "$log" ]; then
        echo "  [OK] Khong co loi gui du lieu"
    else
        echo "  [CANH BAO] Co dong log lien quan:"
        echo "$log" | sed 's/^/      /'
        echo "$log" | grep -qE '401|403|404|unauthorized|not found' && auth_err=1
        echo "$log" | grep -qiE 'timeout|timed out|connect' && net_err=1
    fi

    if [ "$proto" = "udp" ]; then
        echo "  [CANH BAO] Giao thuc UDP: khong truy van duoc InfluxDB de kiem tra. Nen dung HTTP/HTTPS."
        return 0
    fi

    base="$proto://$server:$port${prefix:+/$prefix}"
    echo "  --- 4. Ket noi InfluxDB ($base) ---"
    health=$(curl -sS -k -m 5 "$base/health" 2>&1)
    if echo "$health" | grep -q '"status": *"pass"'; then
        echo "  [OK] InfluxDB tra loi /health"
    else
        echo "  [LOI] Khong ket noi duoc InfluxDB tu $h: $health"
        echo "        Kiem tra firewall/NAT cong $port tu node toi $server"
        return 1
    fi

    token=$(cat "$METRIC_PRIV/$id.pw" 2>/dev/null)
    [ -n "$token" ] || { echo "  [LOI] Khong doc duoc token $METRIC_PRIV/$id.pw"; return 1; }
    q() {
        curl -sS -k -m 20 "$base/api/v2/query?org=$org" \
            -H "Authorization: Token $token" -H "Content-Type: application/vnd.flux" \
            -H "Accept: application/csv" --data "$1" 2>&1
    }

    echo "  --- 5. Du lieu trong bucket '$bucket' (5 phut gan nhat, host=$h) ---"
    local r_sys r_nic
    r_sys=$(q "from(bucket:\"$bucket\") |> range(start:-5m) |> filter(fn:(r)=> r._measurement==\"cpustat\" and r.host==\"$h\" and r._field==\"cpu\") |> last()")
    if echo "$r_sys" | grep -qiE '"code"|error|unauthorized'; then
        echo "  [LOI] InfluxDB tu choi truy van: $(echo "$r_sys" | head -c 300)"
        echo "        Kiem tra token/org/bucket cua metric server '$id'"
        return 1
    fi
    n_sys=$(echo "$r_sys" | influx_rows)
    [ "$n_sys" -gt 0 ] && echo "  [OK] Co du lieu goc Proxmox (cpustat)" || echo "  [LOI] KHONG co du lieu goc Proxmox (cpustat) cua $h"

    r_nic=$(q "from(bucket:\"$bucket\") |> range(start:-5m) |> filter(fn:(r)=> r._measurement==\"nics\" and r.host==\"$h\") |> filter(fn:(r)=> r._field==\"network_up\" or r._field==\"link_speed\" or r._field==\"link_speed_max\" or r._field==\"rx_errors\" or r._field==\"rx_crc_errors\") |> last() |> keep(columns:[\"instance\",\"_field\",\"_value\"]) |> group() |> sort(columns:[\"instance\",\"_field\"])")
    n_nic=$(echo "$r_nic" | influx_rows)
    if [ "$n_nic" -gt 0 ]; then
        echo "  [OK] Co du lieu NIC moi ($n_nic gia tri):"
        echo "$r_nic" | influx_print_nics | head -30
    else
        echo "  [LOI] KHONG co du lieu NIC moi (link_speed, rx_crc_errors...) cua $h"
    fi

    echo "  --- Ket luan ---"
    if [ "$n_sys" -gt 0 ] && [ "$n_nic" -gt 0 ]; then
        echo "  => Du lieu DA VAO InfluxDB. Neu Grafana van trong: chon dung Datasource (Flux) tro toi"
        echo "     $base, org $org, bucket $bucket; chon Server = $h; thoi gian Last 15 minutes."
    elif [ "$n_sys" -gt 0 ]; then
        echo "  => Proxmox gui duoc du lieu goc nhung KHONG co field NIC moi: module/patch chua chay."
        echo "     Chay lai: install, roi xem: journalctl -u pvestatd -n 50"
    elif [ "$auth_err" = 1 ]; then
        echo "  => InfluxDB tu choi du lieu (401/403/404): sai token, org hoac bucket cua metric server '$id'."
    elif [ "$net_err" = 1 ]; then
        echo "  => pvestatd gui bi timeout/loi ket noi. Tang timeout (xem canh bao o muc 2) hoac kiem tra mang."
    else
        echo "  => Proxmox CHUA gui du lieu vao bucket '$bucket'. Kiem tra metric server '$id' dang bat,"
        echo "     dung bucket/org, va xem: journalctl -u pvestatd -n 100"
    fi
    [ "$n_sys" -gt 0 ] && [ "$n_nic" -gt 0 ]
}

if [ "${1:-}" = "--remote" ]; then
    echo "[$(hostname)]"
    # stdin dang la chinh script nay (bash -s), chan lai de lenh con khong doc mat
    case "${2:-}" in
        install)   remote_install < /dev/null ;;
        check)     remote_check < /dev/null ;;
        uninstall) remote_uninstall < /dev/null ;;
        diag)      remote_diag < /dev/null ;;
        *) echo "  action khong hop le: ${2:-}"; exit 2 ;;
    esac
    exit $?
fi

# ======================================================================
# Phan chay tren may dieu khien
# ======================================================================

usage() {
    # In khoi comment dau file (tu dong 2 toi dong trong dau tien)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DASH_TEMPLATE="$SCRIPT_DIR/dashboard-template.json"

# Tao dashboard Grafana tu dashboard-template.json, doi bucket + datasource cho dung cluster nay
make_dashboard() {
    local bucket="${1:-}"

    if [ -z "$bucket" ]; then
        # Lay bucket cua metric server influxdb dau tien trong status.cfg
        bucket=$(influx_cfg bucket)
        if [ -z "$bucket" ]; then
            echo "Khong doc duoc bucket trong /etc/pve/status.cfg. Truyen bucket: $0 dashboard <ten-bucket>"
            return 1
        fi
        echo "Bucket lay tu /etc/pve/status.cfg: $bucket"
    fi
    [ -f "$DASH_TEMPLATE" ] || { echo "Khong thay $DASH_TEMPLATE"; return 1; }

    local out="$SCRIPT_DIR/dashboard-$bucket.json"
    BUCKET="$bucket" GRAFANA_DS="${GRAFANA_DS:-}" perl -MJSON -e '
        local $/;
        open(my $fh, "<", $ARGV[0]) or die "khong mo duoc $ARGV[0]\n";
        my $d = decode_json(<$fh>);
        close($fh);
        my ($b, $ds) = ($ENV{BUCKET}, $ENV{GRAFANA_DS});
        # Escape ky tu dac biet cho regex cua Grafana (JavaScript)
        my $re = sub { (my $s = shift) =~ s{([.*+?^\$\{\}()|\[\]\\/])}{\\$1}g; return "/^$s\$/" };

        # Moi datasource influxdb deu tro ve bien ${dsProxmox}
        my $walk;
        $walk = sub {
            my ($o) = @_;
            if (ref($o) eq "HASH") {
                my $x = $o->{datasource};
                if (ref($x) eq "HASH" && ($x->{type} // "") eq "influxdb") {
                    $x->{uid} = "\${dsProxmox}";
                }
                $walk->($_) foreach values %$o;
            } elsif (ref($o) eq "ARRAY") {
                $walk->($_) foreach @$o;
            }
        };
        $walk->($d);

        foreach my $v (@{ $d->{templating}{list} }) {
            if ($v->{name} eq "dsProxmox") {
                # Co GRAFANA_DS thi chon dung datasource do, khong thi cho chon trong danh sach
                $v->{regex} = $ds ne "" ? $re->($ds) : "";
                $v->{current} = $ds ne "" ? { text => $ds, value => $ds } : {};
            } elsif ($v->{name} eq "Bucket") {
                $v->{regex} = $re->($b);
                $v->{current} = { text => $b, value => $b };
            } elsif ($v->{name} eq "server") {
                $v->{current} = { text => ["All"], value => ["\$__all"] };
                $v->{options} = [];
            }
        }

        (my $slug = lc($b)) =~ s/[^a-z0-9-]+/-/g;
        delete $d->{id};
        $d->{uid} = substr("pve-nic-$slug", 0, 40);
        $d->{title} = "Proxmox Cluster $b";

        open(my $out, ">", $ARGV[1]) or die "khong ghi duoc $ARGV[1]\n";
        print $out JSON->new->utf8->canonical->pretty->encode($d);
        close($out);
    ' "$DASH_TEMPLATE" "$out" || return 1

    echo "[OK] Da tao $out"
    echo "     Title: Proxmox Cluster $bucket"

    if [ -n "${GRAFANA_URL:-}" ] && [ -n "${GRAFANA_TOKEN:-}" ]; then
        local payload resp
        payload=$(mktemp)
        perl -MJSON -e 'local $/; open(my $f, "<", $ARGV[0]) or die; my $d = decode_json(<$f>);
                        print encode_json({ dashboard => $d, overwrite => JSON::true })' "$out" > "$payload"
        # -k: chap nhan chung chi tu ky cua Grafana HTTPS noi bo
        resp=$(curl -sS -k -m 30 -X POST "${GRAFANA_URL%/}/api/dashboards/db" \
            -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" \
            --data-binary "@$payload")
        rm -f "$payload"
        if echo "$resp" | grep -q '"status":"success"'; then
            echo "[OK] Da import vao Grafana: ${GRAFANA_URL%/}$(echo "$resp" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')"
        else
            echo "[LOI] Import Grafana that bai: $resp"
            return 1
        fi
    else
        echo "     Import tay: Grafana -> Dashboards -> New -> Import -> Upload file tren."
        echo "     (Hoac dat GRAFANA_URL va GRAFANA_TOKEN de script import luon)"
    fi
}

ACTION="${1:-}"
shift || true
case "$ACTION" in
    install|check|uninstall|diag) ;;
    dashboard) make_dashboard "${1:-}"; exit $? ;;
    *) usage ;;
esac


load_nodes() {
    local list="$1" line
    # Khong thay o thu muc hien tai thi tim canh script
    if [ ! -f "$list" ] && [ -f "$SCRIPT_DIR/$list" ]; then
        list="$SCRIPT_DIR/$list"
    fi
    if [ ! -f "$list" ]; then
        echo "Khong thay file danh sach node: $1"
        echo "Dang o: $(pwd). File nodes.txt nam cung thu muc voi script: $SCRIPT_DIR"
        exit 1
    fi
    echo "Danh sach node: $list"
    # Bo dong trong, comment, ky tu CR (file sua tren Windows); doc ca dong cuoi khong co xuong dong
    while read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '\r' | xargs)"
        [ -n "$line" ] && NODES+=("$line")
    done < "$list"
}

NODES=()
if [ $# -eq 0 ]; then
    # Khong truyen gi: mac dinh dung nodes.txt canh script
    load_nodes "nodes.txt"
fi
while [ $# -gt 0 ]; do
    if [ "$1" = "-f" ]; then
        if [ -z "${2:-}" ]; then
            echo "Thieu ten file sau -f. Vi du: $0 $ACTION -f nodes.txt"
            exit 2
        fi
        load_nodes "$2"
        shift 2
    else
        NODES+=("$1")
        shift
    fi
done
if [ ${#NODES[@]} -eq 0 ]; then
    echo "Chua co IP node nao. Dien IP vao nodes.txt (moi dong 1 IP) hoac truyen IP truc tiep."
    echo
    usage
fi

SELF="$SCRIPT_DIR/$(basename "$0")"
PM_FILE="$SCRIPT_DIR/$PM_NAME"
SSH_USER="${SSH_USER:-root}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

if [ "$ACTION" = "install" ]; then
    [ -f "$PM_FILE" ] || { echo "Khong thay $PM_FILE"; exit 1; }
    if command -v perl > /dev/null && ! perl -c "$PM_FILE" > /dev/null 2>&1; then
        echo "Loi cu phap trong $PM_FILE:"; perl -c "$PM_FILE"; exit 1
    fi
fi

if [ -n "${SSH_PASS:-}" ]; then
    command -v sshpass > /dev/null || { echo "Da dat SSH_PASS nhung chua cai sshpass"; exit 1; }
    export SSHPASS="$SSH_PASS"
    SSH=(sshpass -e ssh "${SSH_OPTS[@]}")
    SCP=(sshpass -e scp "${SSH_OPTS[@]}")
else
    SSH=(ssh "${SSH_OPTS[@]}")
    SCP=(scp "${SSH_OPTS[@]}")
fi

FAILED=()
for NODE in "${NODES[@]}"; do
    echo "======================================"
    echo "==> $NODE ($ACTION)"
    if [ "$ACTION" = "install" ] && ! "${SCP[@]}" -q "$PM_FILE" "$SSH_USER@$NODE:/tmp/$PM_NAME"; then
        echo "  [LOI] Khong copy duoc file len $NODE"
        FAILED+=("$NODE")
        continue
    fi
    "${SSH[@]}" "$SSH_USER@$NODE" "bash -s -- --remote $ACTION" < "$SELF" || FAILED+=("$NODE")
done

echo "======================================"
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "Hoan thanh: ${#NODES[@]} node OK"
else
    echo "Co ${#FAILED[@]}/${#NODES[@]} node loi: ${FAILED[*]}"
    exit 1
fi
