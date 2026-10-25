#!/bin/bash
# install.sh - Cai Monitor NIC cho ca cluster Proxmox bang 1 lenh
#
# Chay tren 1 node Proxmox bang root:
#   bash install.sh                 (tu lay IP node tu cluster, hoi xac nhan, cai, kiem tra, tao dashboard)
#   bash install.sh -y              (khong hoi)
#   bash install.sh -n "10.0.0.11 10.0.0.12"     (chi cai cac node nay)
#   bash install.sh --no-dashboard  (bo qua buoc dashboard)
#
# Import dashboard luon vao Grafana: dat truoc
#   export GRAFANA_URL=https://<ip-grafana>:3000  GRAFANA_TOKEN='glsa_xxx'  [GRAFANA_DS='ten-datasource']
#
# Cac buoc: 1) kiem tra moi truong  2) lay danh sach node -> deploy/nodes.txt
#           3) install len tung node  4) check  5) tao/import dashboard

set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$REPO_DIR/deploy/deploy-monitor-nic-proxmox.sh"
NODES_FILE="$REPO_DIR/deploy/nodes.txt"
IMPORT_SH="$REPO_DIR/dashboard-grafana/import-dashboard.sh"
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
step "1/5 Kiem tra moi truong"
# ---------------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "Can chay bang root"
command -v pvesh > /dev/null || die "Khong phai node Proxmox (khong co pvesh)"
[ -f "$DEPLOY" ] || die "Khong thay $DEPLOY. Hay clone ca repo, khong copy le tung file."
sed -i 's/\r$//' "$DEPLOY" "$REPO_DIR"/deploy/*.pm "$REPO_DIR"/dashboard-grafana/*.sh 2> /dev/null  # file sua tren Windows
chmod +x "$DEPLOY" "$REPO_DIR"/dashboard-grafana/*.sh "$0" 2> /dev/null
for p in ethtool python3 curl; do
    if ! command -v "$p" > /dev/null; then
        echo "  Cai $p ..."
        apt-get install -y "$p" > /dev/null 2>&1 || die "Khong cai duoc $p (apt-get install -y $p)"
    fi
done
grep -q '^influxdb:' /etc/pve/status.cfg 2> /dev/null \
    || die "Chua cau hinh Metric Server InfluxDB (Datacenter -> Metric Server -> Add -> InfluxDB)"
echo "  [OK] root, Proxmox, ethtool, python3, curl, Metric Server InfluxDB"

# ---------------------------------------------------------------------
step "2/5 Danh sach node"
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
step "3/5 Cai module len cac node"
# ---------------------------------------------------------------------
"$DEPLOY" install -f "$NODES_FILE" || die "Cai dat loi o mot so node (xem output tren). Sua xong chay lai: bash install.sh -y"

# ---------------------------------------------------------------------
step "4/5 Kiem tra"
# ---------------------------------------------------------------------
"$DEPLOY" check -f "$NODES_FILE" || echo "  [CANH BAO] Co node chua dat, chay: $DEPLOY diag -f $NODES_FILE"

# ---------------------------------------------------------------------
step "5/5 Dashboard Grafana"
# ---------------------------------------------------------------------
if [ "$DASHBOARD" = 1 ]; then
    flags=()
    [ "$ASK" = 1 ] || flags+=(-y)
    bucket=$(awk '/^influxdb:/ {s=1; next} /^[a-z]+:/ {s=0} s && $1=="bucket" {print $2; exit}' /etc/pve/status.cfg)
    [ -n "$bucket" ] && flags+=(-b "$bucket")
    bash "$IMPORT_SH" "${flags[@]}" || echo "  [CANH BAO] Chua import duoc dashboard, chay lai: bash $IMPORT_SH"
else
    echo "  Bo qua (--no-dashboard)"
fi

echo
echo "Hoan tat. Sau moi lan 'apt upgrade' nang cap pve-manager, chay lai: bash $REPO_DIR/install.sh -y --no-dashboard"
