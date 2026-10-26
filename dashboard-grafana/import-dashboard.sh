#!/bin/bash
# import-dashboard.sh - Tao va import dashboard "Proxmox Cluster" vao Grafana bang 1 lenh
#
# Cach dung:
#   bash import-dashboard.sh             (hoi lan luot: InfluxDB -> Grafana -> datasource -> ten dashboard)
#   bash import-dashboard.sh -y -i http://10.0.0.5:8086 -O myorg -b proxmox-demo -k 'influx-token' \
#        -u https://10.0.0.5:3000 -t glsa_xxx -n 'Proxmox Cluster Demo'
#   bash import-dashboard.sh -b proxmox-demo -n 'Proxmox Cluster Demo' --no-import   (chi tao file JSON)
#
# Tuy chon (hoac dat bien moi truong cung ten):
#   -i URL        INFLUX_URL      URL InfluxDB 2.x, vi du http://10.0.0.5:8086
#   -O ORG        INFLUX_ORG      Organization InfluxDB
#   -b BUCKET     INFLUX_BUCKET   Bucket ma Proxmox ghi vao
#   -k TOKEN      INFLUX_TOKEN    Token InfluxDB (doc bucket)
#   -u URL        GRAFANA_URL     URL Grafana, vi du https://10.0.0.5:3000
#   -t TOKEN      GRAFANA_TOKEN   Token service account Grafana (role Admin neu can tao datasource)
#   -d TEN_DS     GRAFANA_DS      Ten datasource InfluxDB (Flux) co san. Bo trong: tim theo URL+org, khong co thi tao moi
#   -n TEN        DASH_TITLE      Ten dashboard (mac dinh: Proxmox Cluster <bucket>)
#   -f FOLDER     GRAFANA_FOLDER  Thu muc Grafana de luu dashboard (chua co thi tu tao)
#   -o FILE                       File JSON dau ra (mac dinh: dashboard-<ten>.json canh script)
#   --no-import                   Chi tao file JSON, khong goi API Grafana
#   -y                            Khong hoi gi, dung gia tri da truyen
#
# Chay tren node Proxmox: thong tin InfluxDB mac dinh lay tu Metric Server (/etc/pve/status.cfg).
# Can co: bash, curl, python3. Grafana/InfluxDB HTTPS tu ky van dung duoc (curl -k).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${TEMPLATE:-$SCRIPT_DIR/proxmox-cluster-dashboard.json}"
GRAFANA_URL="${GRAFANA_URL:-}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
GRAFANA_DS="${GRAFANA_DS:-}"
GRAFANA_FOLDER="${GRAFANA_FOLDER:-}"
DASH_TITLE="${DASH_TITLE:-}"
INFLUX_BUCKET="${INFLUX_BUCKET:-${BUCKET:-}}"
OUT=""
DO_IMPORT=1
ASK=1

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        -i) INFLUX_URL="${2:-}"; shift 2 ;;
        -O) INFLUX_ORG="${2:-}"; shift 2 ;;
        -b) INFLUX_BUCKET="${2:-}"; shift 2 ;;
        -k) INFLUX_TOKEN="${2:-}"; shift 2 ;;
        -u) GRAFANA_URL="${2:-}"; shift 2 ;;
        -t) GRAFANA_TOKEN="${2:-}"; shift 2 ;;
        -d) GRAFANA_DS="${2:-}"; shift 2 ;;
        -n) DASH_TITLE="${2:-}"; shift 2 ;;
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
[ -f "$SCRIPT_DIR/influx-common.sh" ] || { echo "[LOI] Khong thay $SCRIPT_DIR/influx-common.sh"; exit 1; }
# shellcheck source=influx-common.sh
. "$SCRIPT_DIR/influx-common.sh"

api() {  # api METHOD PATH [JSON-FILE]
    local args=(-sS -k -m 30 -X "$1" "${GRAFANA_URL%/}$2" -H "Authorization: Bearer $GRAFANA_TOKEN"
                -H "Content-Type: application/json")
    [ -n "${3:-}" ] && args+=(--data-binary "@$3")
    curl "${args[@]}"
}

json_get() {  # json_get KEY  (doc 1 khoa tu JSON tren stdin)
    python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get(sys.argv[1], ""))
except Exception:
    pass' "$1"
}

# ---------------------------------------------------------------------
echo "== 1. InfluxDB"
# ---------------------------------------------------------------------
if [ "${INFLUX_CHECKED:-0}" = 1 ]; then
    echo "  [OK] Dung thong tin InfluxDB da kiem tra: ${INFLUX_URL}, org ${INFLUX_ORG}, bucket ${INFLUX_BUCKET}"
elif [ "$DO_IMPORT" = 1 ]; then
    influx_setup || exit 1
else
    # Chi tao file JSON: chi can bucket
    influx_load_defaults
    [ "$ASK" = 1 ] && ask_req "Bucket InfluxDB cua cluster" INFLUX_BUCKET "$INFLUX_BUCKET"
    [ -n "$INFLUX_BUCKET" ] || { echo "[LOI] Thieu bucket (-b)"; exit 1; }
fi

# ---------------------------------------------------------------------
# 2. Grafana: bat buoc nhap, sai thi nhap lai
# ---------------------------------------------------------------------
if [ "$DO_IMPORT" = 1 ]; then
    echo "== 2. Grafana"
    while :; do
        if [ "$ASK" = 1 ]; then
            ask_req "URL Grafana (vd https://10.0.0.5:3000)" GRAFANA_URL "$GRAFANA_URL"
            ask_secret "Token service account Grafana" GRAFANA_TOKEN
        fi
        if [ -z "$GRAFANA_URL" ] || [ -z "$GRAFANA_TOKEN" ]; then
            echo "  [LOI] Thieu GRAFANA_URL/GRAFANA_TOKEN (-u/-t). Muon chi tao file JSON thi dung --no-import."
            exit 1
        fi
        GRAFANA_URL="${GRAFANA_URL%/}"
        err=""
        health=$(curl -sS -k -m 15 "$GRAFANA_URL/api/health" 2>&1)
        if ! echo "$health" | grep -q '"database"'; then
            err="Khong ket noi duoc Grafana $GRAFANA_URL: $(echo "$health" | head -c 200)"
        else
            ds_json=$(api GET /api/datasources)
            echo "$ds_json" | python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin), list)' 2> /dev/null \
                || err="Token Grafana khong hop le hoac thieu quyen: $(echo "$ds_json" | head -c 200)"
        fi
        [ -z "$err" ] && break
        echo "  [LOI] $err"
        [ "$ASK" = 1 ] || exit 1
        ask_yes "Nhap lai thong tin Grafana?" Y || exit 1
    done
    echo "  [OK] Ket noi Grafana: $GRAFANA_URL"

    # -----------------------------------------------------------------
    echo "== 3. Datasource InfluxDB tren Grafana"
    # -----------------------------------------------------------------
    # Danh sach datasource InfluxDB: "ten<TAB>khop" (khop = cung URL + org voi InfluxDB o buoc 1)
    mapfile -t DS_ROWS < <(echo "$ds_json" | INFLUX_URL="$INFLUX_URL" INFLUX_ORG="$INFLUX_ORG" python3 -c '
import json, os, sys
want_url = os.environ["INFLUX_URL"].rstrip("/").lower()
want_org = os.environ["INFLUX_ORG"]
for d in json.load(sys.stdin):
    if d.get("type") != "influxdb":
        continue
    j = d.get("jsonData") or {}
    match = (d.get("url", "").rstrip("/").lower() == want_url and j.get("organization") == want_org
             and j.get("version") == "Flux")
    print("%s\t%s\t%s" % (d["name"], "1" if match else "0", d.get("url", "")))')

    if [ -n "$GRAFANA_DS" ]; then
        printf '%s\n' "${DS_ROWS[@]}" | cut -f1 | grep -qxF "$GRAFANA_DS" \
            || { echo "  [LOI] Khong co datasource InfluxDB ten '$GRAFANA_DS'"; exit 1; }
    else
        match=""
        for r in "${DS_ROWS[@]}"; do [ "$(echo "$r" | cut -f2)" = 1 ] && { match=$(echo "$r" | cut -f1); break; }; done
        if [ "$ASK" = 1 ]; then
            echo "  InfluxDB can dung: $INFLUX_URL (org $INFLUX_ORG)"
            echo "  0) Tao datasource moi tu thong tin InfluxDB tren"
            for i in "${!DS_ROWS[@]}"; do
                IFS=$'\t' read -r n m u <<< "${DS_ROWS[$i]}"
                printf '  %d) %s  (%s)%s\n' "$((i + 1))" "$n" "$u" "$([ "$m" = 1 ] && echo '  <- khop InfluxDB tren')"
            done
            def=0
            [ -n "$match" ] && for i in "${!DS_ROWS[@]}"; do [ "$(echo "${DS_ROWS[$i]}" | cut -f1)" = "$match" ] && def=$((i + 1)); done
            while :; do
                ask_req "Chon so" pick "$def"
                [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -le ${#DS_ROWS[@]} ] && break
                echo "  (nhap so tu 0 den ${#DS_ROWS[@]})"
            done
            [ "$pick" -gt 0 ] && GRAFANA_DS=$(echo "${DS_ROWS[$((pick - 1))]}" | cut -f1)
        else
            GRAFANA_DS="$match"
        fi
    fi

    if [ -z "$GRAFANA_DS" ]; then
        # Tao datasource moi (can token role Admin)
        ds_name="InfluxDB-${INFLUX_BUCKET}"
        while :; do
            [ "$ASK" = 1 ] && ask_req "Ten datasource moi" ds_name "$ds_name"
            tmp=$(mktemp)
            NAME="$ds_name" INFLUX_URL="$INFLUX_URL" INFLUX_ORG="$INFLUX_ORG" INFLUX_BUCKET="$INFLUX_BUCKET" \
                INFLUX_TOKEN="$INFLUX_TOKEN" python3 -c '
import json, os
e = os.environ
print(json.dumps({
    "name": e["NAME"], "type": "influxdb", "access": "proxy", "url": e["INFLUX_URL"],
    "jsonData": {"version": "Flux", "organization": e["INFLUX_ORG"], "defaultBucket": e["INFLUX_BUCKET"],
                 "tlsSkipVerify": True},
    "secureJsonData": {"token": e["INFLUX_TOKEN"]},
}))' > "$tmp"
            resp=$(api POST /api/datasources "$tmp")
            rm -f "$tmp"
            new_uid=$(echo "$resp" | python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("datasource") or {}).get("uid", ""))
except Exception: pass')
            if [ -n "$new_uid" ]; then
                GRAFANA_DS="$ds_name"
                echo "  [OK] Da tao datasource '$ds_name'"
                break
            fi
            echo "  [LOI] Khong tao duoc datasource: $(echo "$resp" | head -c 200)"
            echo "        (trung ten, hoac token Grafana khong co quyen Admin de tao datasource)"
            [ "$ASK" = 1 ] || exit 1
            ask_yes "Nhap ten khac va thu lai?" Y || exit 1
        done
    fi

    # Kiem tra datasource truy van duoc InfluxDB
    ds_uid=$(api GET "/api/datasources/name/$(urlencode "$GRAFANA_DS")" | json_get uid)
    ds_health=$(api GET "/api/datasources/uid/$ds_uid/health")
    if echo "$ds_health" | grep -q '"status": *"OK"'; then
        echo "  [OK] Datasource: $GRAFANA_DS (ket noi InfluxDB thanh cong)"
    else
        echo "  [CANH BAO] Datasource '$GRAFANA_DS' chua truy van duoc InfluxDB: $(echo "$ds_health" | json_get message)"
        echo "             Grafana phai ket noi duoc $INFLUX_URL. Sua trong Connections -> Data sources neu can."
    fi
fi

# ---------------------------------------------------------------------
echo "== 4. Ten dashboard"
# ---------------------------------------------------------------------
[ -n "$DASH_TITLE" ] || DASH_TITLE="Proxmox Cluster ${INFLUX_BUCKET}"
[ "$ASK" = 1 ] && ask_req "Ten dashboard" DASH_TITLE "$DASH_TITLE"
slug=$(echo "$DASH_TITLE" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')
[ -n "$slug" ] || slug="proxmox"
DASH_UID="pve-${slug}"
DASH_UID="${DASH_UID:0:40}"
[ -n "$OUT" ] || OUT="$SCRIPT_DIR/dashboard-$slug.json"

if [ "$DO_IMPORT" = 1 ]; then
    old=$(api GET "/api/dashboards/uid/$DASH_UID" | python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("dashboard") or {}).get("title", ""))
except Exception: pass')
    if [ -n "$old" ]; then
        echo "  Grafana da co dashboard uid '$DASH_UID' (\"$old\")."
        ask_yes "Ghi de dashboard nay?" Y || { echo "  Huy. Chay lai va dat ten dashboard khac."; exit 1; }
    fi
fi

# ---------------------------------------------------------------------
# 5. Sinh file dashboard
# ---------------------------------------------------------------------
TEMPLATE="$TEMPLATE" OUT="$OUT" BUCKET="$INFLUX_BUCKET" DS="$GRAFANA_DS" TITLE="$DASH_TITLE" UID_="$DASH_UID" \
    python3 - << 'PY' || exit 1
import json, os, re

d = json.load(open(os.environ["TEMPLATE"], encoding="utf-8"))
bucket, ds = os.environ["BUCKET"], os.environ["DS"]

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
d["uid"] = os.environ["UID_"]
d["title"] = os.environ["TITLE"]
with open(os.environ["OUT"], "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
echo "  [OK] Da tao $OUT (title \"$DASH_TITLE\", uid $DASH_UID)"

if [ "$DO_IMPORT" = 0 ]; then
    echo "     Import tay: Grafana -> Dashboards -> New -> Import -> Upload dashboard JSON file -> chon file tren."
    exit 0
fi

# ---------------------------------------------------------------------
echo "== 5. Import vao Grafana"
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
        folder_uid=$(api POST /api/folders "$tmp" | json_get uid)
        rm -f "$tmp"
        [ -n "$folder_uid" ] && echo "  [OK] Da tao thu muc Grafana: $GRAFANA_FOLDER" \
            || { echo "  [LOI] Khong tao duoc thu muc '$GRAFANA_FOLDER'"; exit 1; }
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
    echo "  [OK] Da import vao Grafana: ${GRAFANA_URL%/}$url"
else
    echo "  [LOI] Import that bai: $resp"
    exit 1
fi
