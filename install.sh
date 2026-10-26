#!/bin/bash
# install.sh - Cai Monitor NIC cho ca cluster Proxmox bang 1 lenh
#
# Chay tren 1 node Proxmox bang root:
#   bash install.sh                 (hoi InfluxDB -> node -> cai -> kiem tra -> Grafana + ten dashboard)
#   bash install.sh -y              (khong hoi, dung gia tri tu Metric Server va bien moi truong)
#   bash install.sh -n "10.0.0.11 10.0.0.12"     (chi cai cac node nay)
#   bash install.sh --no-dashboard  (bo qua buoc dashboard)
#
# Chay -y (khong hoi) thi dat truoc cac bien can thiet, vi du:
#   export INFLUX_URL=http://<ip-influx>:8086 INFLUX_ORG=<org> INFLUX_BUCKET=<bucket> INFLUX_TOKEN='...'
#   export GRAFANA_URL=https://<ip-grafana>:3000 GRAFANA_TOKEN='glsa_xxx' DASH_TITLE='Proxmox Cluster A'
#
# Cac buoc: 1) kiem tra moi truong  2) thong tin InfluxDB (+ cap nhat Metric Server Proxmox)
#           3) danh sach node -> deploy/nodes.txt  4) install len tung node  5) check
#           6) Grafana: datasource + ten dashboard + import

set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$REPO_DIR/deploy/deploy-monitor-nic-proxmox.sh"
NODES_FILE="$REPO_DIR/deploy/nodes.txt"
IMPORT_SH="$REPO_DIR/dashboard-grafana/import-dashboard.sh"
COMMON_SH="$REPO_DIR/dashboard-grafana/influx-common.sh"
ASK=1
NODES_ARG=""
DASHBOARD=1

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        -y) ASK=0; shift ;;
        -n) NODES_ARG="${2:-}"; shift 2 ;;
        --no-dashboard) DASHBOARD=0; shift ;;
        -h|--help) usage ;;
        *) echo "Tuy chon khong hop le: $1"; echo; usage ;;
    esac
done
[ -t 0 ] || ASK=0

step() { echo; echo "=============================================="; echo "== $*"; echo "=============================================="; }
die()  { echo "[LOI] $*"; exit 1; }

# ---------------------------------------------------------------------
step "1/6 Kiem tra moi truong"
# ---------------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "Can chay bang root"
command -v pvesh > /dev/null || die "Khong phai node Proxmox (khong co pvesh)"
[ -f "$DEPLOY" ] || die "Khong thay $DEPLOY. Hay clone ca repo, khong copy le tung file."
[ -f "$COMMON_SH" ] || die "Khong thay $COMMON_SH. Hay clone ca repo, khong copy le tung file."
sed -i 's/\r$//' "$DEPLOY" "$REPO_DIR"/deploy/*.pm "$REPO_DIR"/dashboard-grafana/*.sh 2> /dev/null  # file sua tren Windows
chmod +x "$DEPLOY" "$REPO_DIR"/dashboard-grafana/*.sh "$0" 2> /dev/null
for p in ethtool python3 curl; do
    if ! command -v "$p" > /dev/null; then
        echo "  Cai $p ..."
        apt-get install -y "$p" > /dev/null 2>&1 || die "Khong cai duoc $p (apt-get install -y $p)"
    fi
done
echo "  [OK] root, Proxmox, ethtool, python3, curl"
# shellcheck source=dashboard-grafana/influx-common.sh
. "$COMMON_SH"

# ---------------------------------------------------------------------
step "2/6 Thong tin InfluxDB"
# ---------------------------------------------------------------------
influx_setup || die "Thong tin InfluxDB chua dung. Kiem tra URL/org/bucket/token roi chay lai."

# Metric Server cua Proxmox phai ghi dung vao InfluxDB/bucket nay
read -r m_proto m_server m_port m_prefix < <(python3 -c '
import sys, urllib.parse
u = urllib.parse.urlsplit(sys.argv[1])
print(u.scheme or "http", u.hostname or "", u.port or (443 if u.scheme == "https" else 8086), u.path.strip("/") or "-")' "$INFLUX_URL" | tr -d '\r')
[ "$m_prefix" = "-" ] && m_prefix=""
cur_token=""
[ -n "$INFLUX_ID" ] && cur_token=$(cat "$METRIC_PRIV/$INFLUX_ID.pw" 2> /dev/null)
if [ -n "$INFLUX_ID" ] && [ "$(influx_cfg server)" = "$m_server" ] && [ "$(influx_cfg port)" = "$m_port" ] \
    && [ "$(influx_cfg influxdbproto)" = "$m_proto" ] && [ "$(influx_cfg organization)" = "$INFLUX_ORG" ] \
    && [ "$(influx_cfg bucket)" = "$INFLUX_BUCKET" ] && [ "$cur_token" = "$INFLUX_TOKEN" ] \
    && [ "$(influx_cfg api-path-prefix)" = "$m_prefix" ]; then
    echo "  [OK] Metric Server '$INFLUX_ID' cua Proxmox da dung thong tin tren"
else
    args=(--server "$m_server" --port "$m_port" --influxdbproto "$m_proto"
          --organization "$INFLUX_ORG" --bucket "$INFLUX_BUCKET" --token "$INFLUX_TOKEN")
    [ -n "$m_prefix" ] && args+=(--api-path-prefix "$m_prefix")
    [ "$m_proto" = https ] && args+=(--verify-certificate 0)
    if [ -n "$INFLUX_ID" ]; then
        echo "  Metric Server '$INFLUX_ID' cua Proxmox dang khac thong tin vua nhap."
        ask_yes "Cap nhat Metric Server '$INFLUX_ID' theo thong tin moi?" Y || die "Huy. Metric Server phai ghi vao dung InfluxDB/bucket."
        pvesh set "/cluster/metrics/server/$INFLUX_ID" "${args[@]}" > /dev/null || die "Khong cap nhat duoc Metric Server '$INFLUX_ID'"
        echo "  [OK] Da cap nhat Metric Server '$INFLUX_ID'"
    else
        INFLUX_ID="influxdb"
        echo "  Proxmox chua co Metric Server InfluxDB."
        ask_yes "Tao Metric Server '$INFLUX_ID' tro toi $INFLUX_URL, bucket $INFLUX_BUCKET?" Y || die "Huy. Can Metric Server InfluxDB de gui du lieu."
        pvesh create "/cluster/metrics/server/$INFLUX_ID" --type influxdb "${args[@]}" > /dev/null \
            || die "Khong tao duoc Metric Server '$INFLUX_ID'"
        echo "  [OK] Da tao Metric Server '$INFLUX_ID'"
    fi
fi
# Buoc dashboard dung lai, khong hoi InfluxDB lan nua
export INFLUX_URL INFLUX_ORG INFLUX_BUCKET INFLUX_TOKEN INFLUX_CHECKED=1

# ---------------------------------------------------------------------
step "3/6 Danh sach node"
# ---------------------------------------------------------------------
if [ -n "$NODES_ARG" ]; then
    read -ra NODES <<< "$NODES_ARG"
elif grep -qvE '^\s*(#|$)' "$NODES_FILE" 2> /dev/null; then
    mapfile -t NODES < <(sed 's/#.*//; s/\r//' "$NODES_FILE" | xargs -n1)
    echo "  Dung danh sach co san trong deploy/nodes.txt"
else
    # Tu lay IP cac node dang online trong cluster
    mapfile -t NODES < <(pvesh get /cluster/status --output-format json 2> /dev/null | python3 -c '
import json, sys
for n in json.load(sys.stdin):
    if n.get("type") == "node" and n.get("online") and n.get("ip"):
        print(n["ip"])')
    [ ${#NODES[@]} -gt 0 ] || NODES=("$(hostname -I | awk '{print $1}')")
    echo "  Lay tu cluster (pvesh get /cluster/status)"
fi
[ ${#NODES[@]} -gt 0 ] || die "Khong co node nao"
for n in "${NODES[@]}"; do echo "    - $n"; done

if [ "$ASK" = 1 ]; then
    read -r -p "  Cai len ${#NODES[@]} node tren? [Y/n] " ok
    case "${ok:-y}" in y|Y|yes) ;; *) echo "Da huy."; exit 0 ;; esac
fi
{
    echo "# Moi dong 1 IP/hostname node Proxmox, dong bat dau bang # se bi bo qua"
    echo "# Tao boi install.sh luc $(date '+%F %T')"
    printf '%s\n' "${NODES[@]}"
} > "$NODES_FILE"
echo "  [OK] Da ghi deploy/nodes.txt"

# ---------------------------------------------------------------------
step "4/6 Cai module len cac node"
# ---------------------------------------------------------------------
"$DEPLOY" install -f "$NODES_FILE" || die "Cai dat loi o mot so node (xem output tren). Sua xong chay lai: bash install.sh -y"

# ---------------------------------------------------------------------
step "5/6 Kiem tra"
# ---------------------------------------------------------------------
"$DEPLOY" check -f "$NODES_FILE" || echo "  [CANH BAO] Co node chua dat, chay: $DEPLOY diag -f $NODES_FILE"

# ---------------------------------------------------------------------
step "6/6 Dashboard Grafana"
# ---------------------------------------------------------------------
if [ "$DASHBOARD" = 1 ]; then
    flags=()
    [ "$ASK" = 1 ] || flags+=(-y)
    bash "$IMPORT_SH" "${flags[@]}" || echo "  [CANH BAO] Chua import duoc dashboard, chay lai: bash $IMPORT_SH"
else
    echo "  Bo qua (--no-dashboard)"
fi

echo
echo "Hoan tat. Sau moi lan 'apt upgrade' nang cap pve-manager, chay lai: bash $REPO_DIR/install.sh -y --no-dashboard"
