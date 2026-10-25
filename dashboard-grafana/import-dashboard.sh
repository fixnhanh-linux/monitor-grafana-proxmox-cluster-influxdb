#!/bin/bash
# import-dashboard.sh - Tao va import dashboard "Proxmox Cluster" vao Grafana bang 1 lenh
#
# Cach dung:
#   bash import-dashboard.sh                                   (hoi URL, token, datasource, bucket)
#   bash import-dashboard.sh -u https://10.0.0.5:3000 -t glsa_xxx -b proxmox-demo
#   bash import-dashboard.sh -b proxmox-demo --no-import       (chi tao file JSON, import tay)
#
# Tuy chon (hoac dat bien moi truong cung ten):
#   -u URL        GRAFANA_URL     URL Grafana, vi du https://10.0.0.5:3000
#   -t TOKEN      GRAFANA_TOKEN   Token service account (Administration -> Service accounts, role Editor)
#   -d TEN_DS     GRAFANA_DS      Ten datasource InfluxDB (Flux). Bo trong: tu tim, co nhieu thi hoi
#   -b BUCKET     BUCKET          Bucket InfluxDB ma Proxmox ghi vao. Bo trong: chon tren dashboard
#   -f FOLDER     GRAFANA_FOLDER  Thu muc Grafana de luu dashboard (chua co thi tu tao)
#   -o FILE                       File JSON dau ra (mac dinh: dashboard-<bucket>.json canh script)
#   --no-import                   Chi tao file JSON, khong goi API Grafana
#   -y                            Khong hoi gi, dung gia tri da truyen
#
# Can co: bash, curl, python3. Grafana HTTPS tu ky van dung duoc (curl -k).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${TEMPLATE:-$SCRIPT_DIR/proxmox-cluster-dashboard.json}"
GRAFANA_URL="${GRAFANA_URL:-}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
GRAFANA_DS="${GRAFANA_DS:-}"
GRAFANA_FOLDER="${GRAFANA_FOLDER:-}"
BUCKET="${BUCKET:-}"
OUT=""
DO_IMPORT=1
ASK=1

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        -u) GRAFANA_URL="${2:-}"; shift 2 ;;
        -t) GRAFANA_TOKEN="${2:-}"; shift 2 ;;
        -d) GRAFANA_DS="${2:-}"; shift 2 ;;
        -b) BUCKET="${2:-}"; shift 2 ;;
        -f) GRAFANA_FOLDER="${2:-}"; shift 2 ;;
        -o) OUT="${2:-}"; shift 2 ;;
        --no-import) DO_IMPORT=0; shift ;;
        -y) ASK=0; shift ;;
        -h|--help) usage ;;
        *) echo "Tuy chon khong hop le: $1"; echo; usage ;;
    esac
done

# Chi hoi khi dang chay tren terminal va khong co -y
[ -t 0 ] || ASK=0

for c in curl python3; do
    command -v "$c" > /dev/null || { echo "[LOI] Thieu lenh $c (apt install -y $c)"; exit 1; }
done
[ -f "$TEMPLATE" ] || { echo "[LOI] Khong thay file dashboard: $TEMPLATE"; exit 1; }

ask() {  # ask "Cau hoi" bien [mac-dinh]
    local q="$1" var="$2" def="${3:-}" ans
    [ "$ASK" = 1 ] || return 0
    if [ -n "$def" ]; then read -r -p "$q [$def]: " ans; else read -r -p "$q: " ans; fi
    printf -v "$var" '%s' "${ans:-$def}"
}

api() {  # api METHOD PATH [JSON-FILE]
    local args=(-sS -k -m 30 -X "$1" "${GRAFANA_URL%/}$2" -H "Authorization: Bearer $GRAFANA_TOKEN"
                -H "Content-Type: application/json")
    [ -n "${3:-}" ] && args+=(--data-binary "@$3")
    curl "${args[@]}"
}

# ---------------------------------------------------------------------
# 1. Thong tin Grafana
# ---------------------------------------------------------------------
if [ "$DO_IMPORT" = 1 ]; then
    [ -n "$GRAFANA_URL" ]   || ask "URL Grafana (bo trong = chi tao file JSON)" GRAFANA_URL
    [ -n "$GRAFANA_URL" ] && { [ -n "$GRAFANA_TOKEN" ] || ask "Token service account Grafana" GRAFANA_TOKEN; }
    if [ -z "$GRAFANA_URL" ] || [ -z "$GRAFANA_TOKEN" ]; then
        echo "[INFO] Khong co GRAFANA_URL/GRAFANA_TOKEN -> chi tao file JSON."
        DO_IMPORT=0
    fi
fi

if [ "$DO_IMPORT" = 1 ]; then
    health=$(curl -sS -k -m 15 "${GRAFANA_URL%/}/api/health" 2>&1)
    if ! echo "$health" | grep -q '"database"'; then
        echo "[LOI] Khong ket noi duoc Grafana ${GRAFANA_URL}: $health"; exit 1
    fi
    # Kiem tra token bang cach doc danh sach datasource
    ds_json=$(api GET /api/datasources)
    if ! echo "$ds_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,list)' 2> /dev/null; then
        echo "[LOI] Token khong hop le hoac thieu quyen (can role Editor tro len): $ds_json"; exit 1
    fi
    echo "[OK] Ket noi Grafana: ${GRAFANA_URL}"

    # -----------------------------------------------------------------
    # 2. Chon datasource InfluxDB
    # -----------------------------------------------------------------
    mapfile -t DS_LIST < <(echo "$ds_json" | python3 -c '
import json, sys
for d in json.load(sys.stdin):
    if d.get("type") == "influxdb":
        print(d["name"])')
    if [ -n "$GRAFANA_DS" ]; then
        printf '%s\n' "${DS_LIST[@]}" | grep -qxF "$GRAFANA_DS" \
            || { echo "[LOI] Khong co datasource InfluxDB ten '$GRAFANA_DS'. Co: ${DS_LIST[*]:-(khong co)}"; exit 1; }
    elif [ ${#DS_LIST[@]} -eq 1 ]; then
        GRAFANA_DS="${DS_LIST[0]}"
    elif [ ${#DS_LIST[@]} -gt 1 ] && [ "$ASK" = 1 ]; then
        echo "Datasource InfluxDB tren Grafana:"
        for i in "${!DS_LIST[@]}"; do echo "  $((i + 1))) ${DS_LIST[$i]}"; done
        ask "Chon so (bo trong = chon sau tren dashboard)" pick
        [[ "${pick:-}" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#DS_LIST[@]} ] \
            && GRAFANA_DS="${DS_LIST[$((pick - 1))]}"
    elif [ ${#DS_LIST[@]} -eq 0 ]; then
        echo "[CANH BAO] Grafana chua co datasource InfluxDB. Tao datasource InfluxDB (Flux) truoc khi xem dashboard."
    fi
    [ -n "$GRAFANA_DS" ] && echo "[OK] Datasource: $GRAFANA_DS"
fi

# ---------------------------------------------------------------------
# 3. Bucket
# ---------------------------------------------------------------------
if [ -z "$BUCKET" ] && [ -f /etc/pve/status.cfg ]; then
    # Dang chay tren node Proxmox: lay bucket cua metric server InfluxDB dau tien
    BUCKET=$(awk '/^influxdb:/ {s=1; next} /^[a-z]+:/ {s=0} s && $1=="bucket" {print $2; exit}' /etc/pve/status.cfg)
    [ -n "$BUCKET" ] && echo "[OK] Bucket lay tu /etc/pve/status.cfg: $BUCKET"
fi
[ -n "$BUCKET" ] || ask "Bucket InfluxDB cua cluster (bo trong = chon tren dashboard)" BUCKET

# ---------------------------------------------------------------------
# 4. Sinh file dashboard
# ---------------------------------------------------------------------
slug=$(echo "${BUCKET:-proxmox}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9-]\{1,\}/-/g')
[ -n "$OUT" ] || OUT="$SCRIPT_DIR/dashboard-$slug.json"

TEMPLATE="$TEMPLATE" OUT="$OUT" BUCKET="$BUCKET" DS="$GRAFANA_DS" SLUG="$slug" python3 - << 'PY' || exit 1
import json, os, re

d = json.load(open(os.environ["TEMPLATE"], encoding="utf-8"))
bucket, ds, slug = os.environ["BUCKET"], os.environ["DS"], os.environ["SLUG"]

def regex(s):
    # Regex kieu JavaScript cua Grafana, khop dung 1 gia tri
    return "/^" + re.sub(r"([.*+?^${}()|\[\]\\/])", r"\\\1", s) + "$/"

def walk(o):
    # Moi datasource InfluxDB deu tro ve bien ${dsProxmox}
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
    if v.get("name") == "dsProxmox":
        v["regex"] = regex(ds) if ds else ""
        v["current"] = {"text": ds, "value": ds} if ds else {}
    elif v.get("name") == "Bucket":
        v["regex"] = regex(bucket) if bucket else ""
        v["current"] = {"text": bucket, "value": bucket} if bucket else {}
    elif v.get("name") == "server":
        v["current"] = {"text": ["All"], "value": ["$__all"]}
        v["options"] = []

d.pop("id", None)
d["uid"] = ("pve-nic-" + slug)[:40]
d["title"] = "Proxmox Cluster " + bucket if bucket else "Proxmox Cluster"
with open(os.environ["OUT"], "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
echo "[OK] Da tao $OUT"

if [ "$DO_IMPORT" = 0 ]; then
    echo "     Import tay: Grafana -> Dashboards -> New -> Import -> Upload dashboard JSON file -> chon file tren."
    exit 0
fi

# ---------------------------------------------------------------------
# 5. Import qua API
# ---------------------------------------------------------------------
folder_uid=""
if [ -n "$GRAFANA_FOLDER" ]; then
    folder_uid=$(api GET /api/folders | FOLDER="$GRAFANA_FOLDER" python3 -c '
import json, os, sys
for f in json.load(sys.stdin):
    if f.get("title") == os.environ["FOLDER"]:
        print(f["uid"]); break')
    if [ -z "$folder_uid" ]; then
        tmp=$(mktemp)
        FOLDER="$GRAFANA_FOLDER" python3 -c 'import json,os; print(json.dumps({"title": os.environ["FOLDER"]}))' > "$tmp"
        folder_uid=$(api POST /api/folders "$tmp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("uid",""))')
        rm -f "$tmp"
        [ -n "$folder_uid" ] && echo "[OK] Da tao thu muc Grafana: $GRAFANA_FOLDER" \
            || { echo "[LOI] Khong tao duoc thu muc '$GRAFANA_FOLDER'"; exit 1; }
    fi
fi

payload=$(mktemp)
FOLDER_UID="$folder_uid" python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
p = {"dashboard": d, "overwrite": True, "message": "import-dashboard.sh"}
if os.environ["FOLDER_UID"]:
    p["folderUid"] = os.environ["FOLDER_UID"]
print(json.dumps(p))' "$OUT" > "$payload"
resp=$(api POST /api/dashboards/db "$payload")
rm -f "$payload"

url=$(echo "$resp" | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if r.get("status") != "success":
    sys.exit(1)
print(r.get("url", ""))' 2> /dev/null)
if [ $? -eq 0 ]; then
    echo "[OK] Da import vao Grafana: ${GRAFANA_URL%/}$url"
else
    echo "[LOI] Import that bai: $resp"
    exit 1
fi
