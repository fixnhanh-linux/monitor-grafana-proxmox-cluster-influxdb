#!/bin/bash
# export-dashboard.sh - Lay dashboard dang chay tren Grafana, lam sach va luu de dua len GitHub
#
# Dung khi da sua giao dien dashboard tren Grafana va muon cap nhat file mau trong repo.
#
# Cach dung:
#   bash export-dashboard.sh -u https://10.0.0.5:3000 -t glsa_xxx -i adpmac64
#   bash export-dashboard.sh                                (hoi URL, token, UID)
#
# Tuy chon (hoac bien moi truong):
#   -u URL     GRAFANA_URL     URL Grafana
#   -t TOKEN   GRAFANA_TOKEN   Token service account (role Viewer la du)
#   -i UID     DASHBOARD_UID   UID dashboard: phan sau /d/ tren URL, vi du .../d/adpmac64/... -> adpmac64
#   -o FILE                    File dau ra (mac dinh: proxmox-cluster-dashboard.json canh script)
#
# Lam sach: bo id/version, datasource InfluxDB -> bien ${dsProxmox}, xoa bucket/datasource/node
# dang chon, dat title "Proxmox Cluster" va uid "pve-cluster-nic". Sau do: git add + commit file.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRAFANA_URL="${GRAFANA_URL:-}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
DASHBOARD_UID="${DASHBOARD_UID:-}"
OUT="$SCRIPT_DIR/proxmox-cluster-dashboard.json"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        -u) GRAFANA_URL="${2:-}"; shift 2 ;;
        -t) GRAFANA_TOKEN="${2:-}"; shift 2 ;;
        -i) DASHBOARD_UID="${2:-}"; shift 2 ;;
        -o) OUT="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Tuy chon khong hop le: $1"; echo; usage ;;
    esac
done

for c in curl python3; do
    command -v "$c" > /dev/null || { echo "[LOI] Thieu lenh $c (apt install -y $c)"; exit 1; }
done

if [ -t 0 ]; then
    [ -n "$GRAFANA_URL" ]   || read -r -p "URL Grafana: " GRAFANA_URL
    [ -n "$GRAFANA_TOKEN" ] || read -r -p "Token service account Grafana: " GRAFANA_TOKEN
    [ -n "$DASHBOARD_UID" ] || read -r -p "UID dashboard (phan sau /d/ tren URL): " DASHBOARD_UID
fi
if [ -z "$GRAFANA_URL" ] || [ -z "$GRAFANA_TOKEN" ] || [ -z "$DASHBOARD_UID" ]; then
    echo "[LOI] Can du GRAFANA_URL, GRAFANA_TOKEN va DASHBOARD_UID"; echo; usage
fi

tmp=$(mktemp)
code=$(curl -sS -k -m 30 -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $GRAFANA_TOKEN" \
    "${GRAFANA_URL%/}/api/dashboards/uid/$DASHBOARD_UID")
if [ "$code" != "200" ]; then
    echo "[LOI] Grafana tra ve HTTP $code: $(head -c 300 "$tmp")"; rm -f "$tmp"; exit 1
fi

python3 - "$tmp" "$OUT" << 'PY' || { rm -f "$tmp"; exit 1; }
import json, sys

d = json.load(open(sys.argv[1], encoding="utf-8"))["dashboard"]

def walk(o):
    if isinstance(o, dict):
        x = o.get("datasource")
        if isinstance(x, dict) and x.get("type") == "influxdb":
            x["uid"] = "${dsProxmox}"
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(d)

for v in d.get("templating", {}).get("list", []):
    if v.get("name") in ("dsProxmox", "Bucket"):
        v["regex"] = ""
        v["current"] = {}
    elif v.get("name") == "server":
        v["current"] = {"text": ["All"], "value": ["$__all"]}
        v["options"] = []

for k in ("id", "version"):
    d.pop(k, None)
d["uid"] = "pve-cluster-nic"
d["title"] = "Proxmox Cluster"

with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("[OK] %d panel, da luu %s" % (len(d.get("panels", [])), sys.argv[2]))
PY
rm -f "$tmp"
echo "     Tiep theo: git add $(basename "$OUT") && git commit -m 'Cap nhat dashboard' && git push"
