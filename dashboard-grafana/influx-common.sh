#!/bin/bash
# influx-common.sh - Ham dung chung cho install.sh va import-dashboard.sh (duoc "source", khong chay rieng)
#
# Hoi va kiem tra thong tin InfluxDB 2.x:
#   INFLUX_URL     vi du http://10.0.0.5:8086
#   INFLUX_ORG     organization
#   INFLUX_BUCKET  bucket Proxmox ghi vao
#   INFLUX_TOKEN   token doc/ghi bucket
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

# Kiem tra ket noi, token, org va bucket
influx_test() {
    local h r n
    h=$(curl -sS -k -m 10 "${INFLUX_URL%/}/health" 2>&1)
    if ! echo "$h" | grep -q '"status": *"pass"'; then
        echo "  [LOI] Khong ket noi duoc InfluxDB ${INFLUX_URL}: $(echo "$h" | head -c 200)"
        return 1
    fi
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
        return 1
    fi
    echo "  [OK] InfluxDB ${INFLUX_URL}, org ${INFLUX_ORG}, bucket ${INFLUX_BUCKET}"
}

# Hoi (neu ASK=1) va kiem tra thong tin InfluxDB; sai thi cho nhap lai
influx_setup() {
    influx_load_defaults
    while :; do
        if [ "${ASK:-1}" = 1 ]; then
            echo "  Thong tin InfluxDB (Enter = giu gia tri trong [ ]):"
            ask_req "URL InfluxDB (vd http://10.0.0.5:8086)" INFLUX_URL "$INFLUX_URL"
            ask_req "Organization" INFLUX_ORG "$INFLUX_ORG"
            ask_req "Bucket" INFLUX_BUCKET "$INFLUX_BUCKET"
            ask_secret "Token InfluxDB" INFLUX_TOKEN
        fi
        local miss=()
        for v in INFLUX_URL INFLUX_ORG INFLUX_BUCKET INFLUX_TOKEN; do [ -n "${!v}" ] || miss+=("$v"); done
        if [ ${#miss[@]} -gt 0 ]; then
            echo "  [LOI] Thieu ${miss[*]} (dat bien moi truong hoac chay khong co -y de nhap)"
            return 1
        fi
        INFLUX_URL="${INFLUX_URL%/}"
        influx_test && return 0
        [ "${ASK:-1}" = 1 ] || return 1
        ask_yes "Nhap lai thong tin InfluxDB?" Y || return 1
    done
}
