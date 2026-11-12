#!/bin/bash
# influx-common.sh - Ham dung chung cho install.sh va import-dashboard.sh (duoc "source", khong chay rieng)
#
# Hoi va kiem tra thong tin InfluxDB 2.x:
#   INFLUX_URL     vi du http://10.0.0.5:8086
#   INFLUX_ORG     organization (de trong: tu lay neu token admin chi thay 1 org)
#   INFLUX_BUCKET  bucket Proxmox ghi vao (mac dinh proxmox-cluster-vm-<ten host>, token cung ten)
#   INFLUX_TOKEN   token doc/ghi bucket, HOAC token admin/All-Access:
#                  script tu tao bucket (neu chua co) + token doc/ghi rieng cho bucket, roi dung token do
#   INFLUX_RETENTION_DAYS  so ngay luu du lieu khi tu tao bucket (0 = vo han, mac dinh 0)
# Gia tri mac dinh lay tu Metric Server InfluxDB cua Proxmox (/etc/pve/status.cfg) neu chay tren node.
# ASK=1: hoi tung muc (Enter = giu gia tri mac dinh). ASK=0: chi dung gia tri co san.

STATUS_CFG="${STATUS_CFG:-/etc/pve/status.cfg}"
METRIC_PRIV="${METRIC_PRIV:-/etc/pve/priv/metricserver}"
INFLUX_URL="${INFLUX_URL:-}"
INFLUX_ORG="${INFLUX_ORG:-}"
INFLUX_BUCKET="${INFLUX_BUCKET:-}"
INFLUX_TOKEN="${INFLUX_TOKEN:-}"
INFLUX_ID="${INFLUX_ID:-}"

# Doc 1 gia tri cua metric server influxdb dau tien trong status.cfg ("id" = ten metric server)
influx_cfg() {
    awk -v k="$1" '
        /^influxdb:/ { s = 1; if (k == "id") { print $2; exit } next }
        /^[a-z]+:/   { s = 0 }
        s && $1 == k { print $2; exit }' "$STATUS_CFG" 2> /dev/null
}

# Bat buoc nhap (Enter = gia tri mac dinh neu co)
ask_req() {  # ask_req "Cau hoi" bien [mac-dinh]
    local q="$1" var="$2" def="${3:-}" ans
    while :; do
        if [ -n "$def" ]; then read -r -p "  $q [$def]: " ans; else read -r -p "  $q: " ans; fi
        ans="${ans:-$def}"
        [ -n "$ans" ] && break
        echo "  (bat buoc nhap)"
    done
    printf -v "$var" '%s' "$ans"
}

# Nhap bi mat (khong hien ky tu). Enter = giu gia tri hien tai cua bien
ask_secret() {  # ask_secret "Cau hoi" bien
    local q="$1" var="$2" cur="${!2:-}" ans
    while :; do
        if [ -n "$cur" ]; then
            read -r -s -p "  $q [Enter = giu gia tri hien tai]: " ans
        else
            read -r -s -p "  $q: " ans
        fi
        echo
        ans="${ans:-$cur}"
        [ -n "$ans" ] && break
        echo "  (bat buoc nhap)"
    done
    printf -v "$var" '%s' "$ans"
}

ask_yes() {  # ask_yes "Cau hoi" [Y|N]  -> 0 neu dong y
    local def="${2:-Y}" ans
    [ "${ASK:-1}" = 1 ] || { [ "$def" = Y ]; return; }
    read -r -p "  $1 [$( [ "$def" = Y ] && echo Y/n || echo y/N )] " ans
    case "${ans:-$def}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# Gia tri mac dinh tu Metric Server InfluxDB cua Proxmox (neu co)
influx_load_defaults() {
    local proto server port prefix
    INFLUX_ID="${INFLUX_ID:-$(influx_cfg id)}"
    server=$(influx_cfg server)
    if [ -z "$INFLUX_URL" ] && [ -n "$server" ]; then
        proto=$(influx_cfg influxdbproto)
        port=$(influx_cfg port)
        prefix=$(influx_cfg api-path-prefix)
        # UDP khong truy van duoc, goi y HTTP
        [ -z "$proto" ] || [ "$proto" = udp ] && proto=http
        INFLUX_URL="$proto://$server:${port:-8086}${prefix:+/$prefix}"
    fi
    [ -n "$INFLUX_ORG" ] || INFLUX_ORG=$(influx_cfg organization)
    [ -n "$INFLUX_BUCKET" ] || INFLUX_BUCKET=$(influx_cfg bucket)
    if [ -z "$INFLUX_TOKEN" ] && [ -n "$INFLUX_ID" ]; then
        INFLUX_TOKEN=$(cat "$METRIC_PRIV/$INFLUX_ID.pw" 2> /dev/null)
    fi
}

# Goi API InfluxDB bang $INFLUX_TOKEN. In body, dong cuoi la HTTP code
influx_api() {  # influx_api METHOD PATH [JSON]
    local args=(-sS -k -m 15 -X "$1" "${INFLUX_URL%/}$2" -H "Authorization: Token $INFLUX_TOKEN"
                -H "Content-Type: application/json" -w '\n%{http_code}')
    [ -n "${3:-}" ] && args+=(--data-binary "$3")
    curl "${args[@]}" 2>&1
}

influx_health() {
    local h
    h=$(curl -sS -k -m 10 "${INFLUX_URL%/}/health" 2>&1)
    echo "$h" | grep -q '"status": *"pass"' && return 0
    echo "  [LOI] Khong ket noi duoc InfluxDB ${INFLUX_URL}: $(echo "$h" | head -c 200)"
    return 1
}

# Token admin/All-Access (doc duoc org + quan ly token): tu tao bucket (neu chua co) va token
# doc/ghi rieng cho bucket, roi thay INFLUX_TOKEN bang token do.
# Tra ve: 0 = xong, 1 = loi, 2 = token khong phai admin (giu nguyen token, kiem tra binh thuong)
influx_provision() {
    local r code body row org_id org_name bucket_id ret desc tok
    r=$(influx_api GET "/api/v2/orgs?limit=100"); code=${r##*$'\n'}; body=${r%$'\n'*}
    [ "$code" = 200 ] || return 2
    row=$(echo "$body" | ORG="$INFLUX_ORG" python3 -c '
import json, os, sys
orgs = json.load(sys.stdin).get("orgs") or []
want = os.environ["ORG"]
if not orgs:
    sys.exit(0)
m = [o for o in orgs if o.get("name") == want] if want else orgs
if len(m) == 1:
    print("OK\t%s\t%s" % (m[0]["id"], m[0]["name"]))
else:
    print("ERR\t" + ", ".join(o.get("name", "") for o in orgs))' 2> /dev/null)
    [ -n "$row" ] || return 2   # token khong doc duoc org nao -> token cua bucket
    IFS=$'\t' read -r code org_id org_name <<< "$row"
    if [ "$code" != OK ]; then
        if [ -n "$INFLUX_ORG" ]; then echo "  [LOI] Khong co org '$INFLUX_ORG'. Cac org hien co: $org_id"
        else echo "  [LOI] Token thay nhieu org ($org_id), hay nhap Organization"; fi
        return 1
    fi
    # Co quyen quan ly token khong? (API tra 200 + danh sach rong neu khong co quyen; token admin
    # luon thay it nhat chinh no) Khong co -> coi nhu token thuong
    r=$(influx_api GET "/api/v2/authorizations?limit=1"); code=${r##*$'\n'}; body=${r%$'\n'*}
    [ "$code" = 200 ] || return 2
    echo "$body" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("authorizations") else 1)' \
        2> /dev/null || return 2
    INFLUX_ORG="$org_name"
    echo "  Token co quyen admin tren org '$INFLUX_ORG' -> tu chuan bi bucket va token"

    # --- Bucket ---
    r=$(influx_api GET "/api/v2/buckets?orgID=$org_id&name=$(urlencode "$INFLUX_BUCKET")")
    code=${r##*$'\n'}; body=${r%$'\n'*}
    bucket_id=""
    [ "$code" = 200 ] && bucket_id=$(echo "$body" | python3 -c '
import json, sys
b = json.load(sys.stdin).get("buckets") or []
print(b[0]["id"] if b else "")' 2> /dev/null)
    if [ -n "$bucket_id" ]; then
        echo "  [TRUNG] Bucket '$INFLUX_BUCKET' da ton tai -> dung lai, khong tao moi"
    else
        ask_yes "Bucket '$INFLUX_BUCKET' chua co. Tao moi?" Y || { echo "  [LOI] Can bucket de luu du lieu"; return 1; }
        ret="${INFLUX_RETENTION_DAYS:-0}"
        if [ "${ASK:-1}" = 1 ]; then
            while :; do
                ask_req "Thoi gian luu du lieu (so ngay, 0 = vo han)" ret "$ret"
                [[ "$ret" =~ ^[0-9]+$ ]] && break
                echo "  (nhap so ngay, vd 30)"
            done
        fi
        [[ "$ret" =~ ^[0-9]+$ ]] || { echo "  [LOI] INFLUX_RETENTION_DAYS phai la so ngay"; return 1; }
        body=$(ORG_ID="$org_id" NAME="$INFLUX_BUCKET" RET="$ret" python3 -c '
import json, os
e = os.environ
print(json.dumps({"orgID": e["ORG_ID"], "name": e["NAME"], "description": "Proxmox metrics",
                  "retentionRules": [{"type": "expire", "everySeconds": int(e["RET"]) * 86400}]}))')
        r=$(influx_api POST /api/v2/buckets "$body"); code=${r##*$'\n'}; body=${r%$'\n'*}
        bucket_id=$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' 2> /dev/null)
        if [ "$code" != 201 ] || [ -z "$bucket_id" ]; then
            echo "  [LOI] Khong tao duoc bucket: $(echo "$body" | head -c 200)"
            return 1
        fi
        echo "  [OK] Da tao bucket '$INFLUX_BUCKET' (luu $([ "$ret" = 0 ] && echo "vo han" || echo "$ret ngay"))"
    fi

    # --- Token rieng cho bucket (doc + ghi) ---
    ask_yes "Tao/dung token rieng (doc+ghi chi bucket '$INFLUX_BUCKET') thay cho token admin?" Y || {
        echo "  Giu token admin cho Metric Server va Grafana"; return 0; }
    # Token dat ten (description) trung ten bucket. Da co -> bao trung, dung lai, khong tao moi
    desc="$INFLUX_BUCKET"
    r=$(influx_api GET "/api/v2/authorizations?orgID=$org_id"); body=${r%$'\n'*}
    row=$(echo "$body" | DESC="$desc" BID="$bucket_id" python3 -c '
import json, os, sys
same = [a for a in json.load(sys.stdin).get("authorizations") or [] if a.get("description") == os.environ["DESC"]]
def acts(a):
    return {p["action"] for p in a.get("permissions", [])
            if p.get("resource", {}).get("type") == "buckets" and p["resource"].get("id") == os.environ["BID"]}
ok = [a for a in same if a.get("status") == "active" and {"read", "write"} <= acts(a)]
if ok:
    print("OK\t" + (ok[0].get("token") or ""))
elif same:
    print("BAD\t" + ("inactive" if all(a.get("status") != "active" for a in same) else "noperm"))
else:
    print("NONE\t")' 2> /dev/null)
    IFS=$'\t' read -r code tok <<< "$row"
    if [ "$code" = BAD ]; then
        echo "  [TRUNG] Da co token ten '$desc' nhung $([ "$tok" = inactive ] && echo "dang bi tat (inactive)" || echo "khong du quyen doc+ghi bucket")."
        echo "          Sua/xoa token do trong InfluxDB UI (Load Data -> API Tokens) roi chay lai."
        return 1
    elif [ "$code" = OK ] && [ -n "$tok" ]; then
        echo "  [TRUNG] Token '$desc' da ton tai -> dung lai, khong tao moi"
    elif [ "$code" = OK ]; then
        # InfluxDB ban moi/Cloud khong tra lai gia tri token cu
        echo "  [TRUNG] Token '$desc' da ton tai -> khong tao moi"
        if [ -n "${INFLUX_OLD_TOKEN:-}" ] && [ "$INFLUX_OLD_TOKEN" != "$INFLUX_TOKEN" ]; then
            echo "          InfluxDB khong tra lai gia tri token, dung token dang luu trong Metric Server Proxmox"
            tok="$INFLUX_OLD_TOKEN"
        else
            echo "  [LOI] InfluxDB khong tra lai gia tri token '$desc'. Nhap chinh token do thay cho token admin,"
            echo "        hoac xoa token '$desc' trong InfluxDB UI roi chay lai de tao moi."
            return 1
        fi
    else
        body=$(ORG_ID="$org_id" BID="$bucket_id" DESC="$desc" python3 -c '
import json, os
e = os.environ
res = {"type": "buckets", "id": e["BID"], "orgID": e["ORG_ID"]}
print(json.dumps({"orgID": e["ORG_ID"], "description": e["DESC"], "status": "active",
                  "permissions": [{"action": "read", "resource": res}, {"action": "write", "resource": res}]}))')
        r=$(influx_api POST /api/v2/authorizations "$body"); code=${r##*$'\n'}; body=${r%$'\n'*}
        tok=$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))' 2> /dev/null)
        if [ "$code" != 201 ] || [ -z "$tok" ]; then
            echo "  [LOI] Khong tao duoc token cho bucket: $(echo "$body" | head -c 200)"
            return 1
        fi
        echo "  [OK] Da tao token '$desc' (doc+ghi bucket $INFLUX_BUCKET)"
    fi
    INFLUX_TOKEN="$tok"
    return 0
}

# Kiem tra token doc duoc bucket trong org
influx_test() {
    local r n
    influx_health || return 1
    r=$(curl -sS -k -m 15 "${INFLUX_URL%/}/api/v2/query?org=$(urlencode "$INFLUX_ORG")" \
        -H "Authorization: Token $INFLUX_TOKEN" -H "Content-Type: application/vnd.flux" -H "Accept: application/csv" \
        --data "buckets() |> filter(fn: (r) => r.name == \"$INFLUX_BUCKET\")" 2>&1)
    if echo "$r" | grep -qE '"code"|"message"'; then
        echo "  [LOI] InfluxDB tu choi (sai token hoac org '$INFLUX_ORG'): $(echo "$r" | head -c 200)"
        return 1
    fi
    n=$(echo "$r" | tr -d '\r' | awk -F, 'NF > 1 && $2 != "result" && $1 !~ /^#/ { n++ } END { print n + 0 }')
    if [ "$n" -eq 0 ]; then
        echo "  [LOI] Org '$INFLUX_ORG' khong co bucket '$INFLUX_BUCKET' (hoac token khong co quyen doc bucket)"
        echo "        Nhap token admin/All-Access de script tu tao bucket va token."
        return 1
    fi
    echo "  [OK] InfluxDB ${INFLUX_URL}, org ${INFLUX_ORG}, bucket ${INFLUX_BUCKET}"
}

# Nhap khong bat buoc (Enter = giu gia tri mac dinh, co the de trong)
ask_opt() {  # ask_opt "Cau hoi" bien [mac-dinh]
    local q="$1" var="$2" def="${3:-}" ans
    if [ -n "$def" ]; then read -r -p "  $q [$def]: " ans; else read -r -p "  $q: " ans; fi
    printf -v "$var" '%s' "${ans:-$def}"
}

# Hoi (neu ASK=1) va kiem tra thong tin InfluxDB; sai thi cho nhap lai.
# Token admin/All-Access -> tu tao bucket + token rieng cua bucket (influx_provision).
influx_setup() {
    local rc
    influx_load_defaults
    INFLUX_OLD_TOKEN="$INFLUX_TOKEN"   # token dang luu trong Metric Server (neu co)
    # Ten bucket mac dinh (cung la ten token): proxmox-cluster-vm-<ten host Proxmox>
    if [ -z "$INFLUX_BUCKET" ]; then
        local h
        h=$(hostname 2> /dev/null); h="${h%%.*}"
        h=$(echo "$h" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')
        INFLUX_BUCKET="proxmox-cluster-vm-${h:-node}"
    fi
    while :; do
        if [ "${ASK:-1}" = 1 ]; then
            echo "  Thong tin InfluxDB (Enter = giu gia tri trong [ ]):"
            echo "  * Token admin/All-Access: script tu tao bucket (neu chua co) + token rieng cho bucket"
            echo "  * Token cua bucket co san: dung luon token do"
            ask_req "URL InfluxDB (vd http://10.0.0.5:8086)" INFLUX_URL "$INFLUX_URL"
            ask_opt "Organization (de trong = tu lay neu token admin chi co 1 org)" INFLUX_ORG "$INFLUX_ORG"
            ask_req "Bucket (cung la ten token)" INFLUX_BUCKET "$INFLUX_BUCKET"
            ask_secret "Token InfluxDB" INFLUX_TOKEN
        fi
        local miss=()
        for v in INFLUX_URL INFLUX_BUCKET INFLUX_TOKEN; do [ -n "${!v}" ] || miss+=("$v"); done
        if [ ${#miss[@]} -gt 0 ]; then
            echo "  [LOI] Thieu ${miss[*]} (dat bien moi truong hoac chay khong co -y de nhap)"
            return 1
        fi
        INFLUX_URL="${INFLUX_URL%/}"
        if influx_health; then
            influx_provision; rc=$?
            if [ "$rc" = 2 ] && [ -z "$INFLUX_ORG" ]; then
                echo "  [LOI] Token khong phai admin, can nhap Organization"
                rc=1
            fi
            [ "$rc" != 1 ] && influx_test && return 0
        fi
        [ "${ASK:-1}" = 1 ] || return 1
        ask_yes "Nhap lai thong tin InfluxDB?" Y || return 1
    done
}
