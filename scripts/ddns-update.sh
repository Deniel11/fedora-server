#!/usr/bin/env bash

set -Eeuo pipefail

STATE_DIR="/etc/fedora-server-setup"
CREDENTIALS="${STATE_DIR}/godaddy.ini"
DDNS_DIR="${STATE_DIR}/ddns.d"
API_ROOT="https://api.godaddy.com/v3/domains/zones"
TTL=600

log() {
    printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

warn() {
    log "WARN: $*" >&2
}

TEMP_FILES=()

cleanup_temp_files() {
    local file
    for file in "${TEMP_FILES[@]}"; do
        [[ -n "$file" ]] && rm -f -- "$file"
    done
}

trap cleanup_temp_files EXIT HUP INT TERM

[[ -s "$CREDENTIALS" ]] || {
    warn "GoDaddy credentials are missing."
    exit 1
}

source "$CREDENTIALS"
[[ -n "${GODADDY_PAT:-}" ]] || {
    warn "GoDaddy PAT is missing."
    exit 1
}

ipv4="$(curl --ipv4 --fail --silent --show-error --max-time 15 https://api.ipify.org 2>/dev/null || true)"
if [[ -n "$ipv4" ]] && python3 - "$ipv4" <<'PY'
import ipaddress
import sys
try:
    value = ipaddress.ip_address(sys.argv[1])
    raise SystemExit(0 if value.version == 4 and value.is_global else 1)
except ValueError:
    raise SystemExit(1)
PY
then
    :
else
    ipv4=""
    warn "Unable to determine a globally routable public IPv4 address."
fi

ipv6="$(curl --ipv6 --fail --silent --show-error --max-time 15 https://api.ipify.org 2>/dev/null || true)"
if [[ -n "$ipv6" ]] && python3 - "$ipv6" <<'PY'
import ipaddress
import sys
try:
    value = ipaddress.ip_address(sys.argv[1])
    raise SystemExit(0 if value.version == 6 and value.is_global else 1)
except ValueError:
    raise SystemExit(1)
PY
then
    :
else
    ipv6=""
    warn "No globally routable public IPv6 address detected; AAAA records will be left unchanged."
fi

api_get() {
    curl --fail --silent --show-error --max-time 25 \
        -H "Authorization: Bearer ${GODADDY_PAT}" \
        -H "Accept: application/json" "$1"
}

fetch_records() {
    local url="$1"
    local query="$2"
    local destination="$3"
    local page=1 page_file count

    printf '{"items":[]}' > "$destination"

    while true; do
        page_file="$(mktemp)"
        TEMP_FILES+=("$page_file")
        if ! api_get "${url}?${query}&page=${page}&pageSize=100" > "$page_file"; then
            warn "Unable to read DNS records from ${url}."
            rm -f -- "$page_file"
            return 1
        fi

        count="$(python3 - "$destination" "$page_file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    current = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    page = json.load(stream)
items = page.get("items", [])
current.setdefault("items", []).extend(items)
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(current, stream)
print(len(items))
PY
)"
        rm -f -- "$page_file"

        (( count < 100 )) && break
        page=$((page + 1))
    done
}

record_summary() {
    python3 - "$1" "$2" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
records = [item for item in payload.get("items", []) if item.get("type") == sys.argv[2]]
if not records:
    print("0\t\t\t")
elif len(records) > 1:
    print(f"{len(records)}\t\t\t")
else:
    item = records[0]
    print("1\t{}\t{}\t{}".format(item.get("recordId", ""), item.get("data", ""), item.get("ttl", 600)))
PY
}

has_cname() {
    python3 - "$1" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
raise SystemExit(0 if any(item.get("type") == "CNAME" for item in payload.get("items", [])) else 1)
PY
}

json_body() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json
import sys
print(json.dumps({"name": sys.argv[1], "type": sys.argv[2], "data": sys.argv[3], "ttl": int(sys.argv[4])}))
PY
}

reconcile_record() {
    local zone="$1"
    local name="$2"
    local type="$3"
    local address="$4"
    local all_file type_file summary count record_id old_data old_ttl body url encoded_name encoded_id

    [[ -n "$address" ]] || return 0
    all_file="$(mktemp)"
    type_file="$(mktemp)"
    TEMP_FILES+=("$all_file" "$type_file")
    url="${API_ROOT}/${zone}/dns-records"
    encoded_name="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$name")"

    if ! fetch_records "$url" "name=${encoded_name}" "$all_file"; then
        warn "Unable to read DNS records for ${name}.${zone}."
        rm -f "$all_file" "$type_file"
        return 1
    fi

    if has_cname "$all_file"; then
        log "${name}.${zone} is a CNAME alias; leaving it unchanged."
        rm -f "$all_file" "$type_file"
        return 0
    fi

    if ! fetch_records "$url" "type=${type}&name=${encoded_name}" "$type_file"; then
        warn "Unable to read ${type} records for ${name}.${zone}."
        rm -f "$all_file" "$type_file"
        return 1
    fi

    summary="$(record_summary "$type_file" "$type")"
    IFS=$'\t' read -r count record_id old_data old_ttl <<< "$summary"

    if [[ "$count" == "0" ]]; then
        body="$(json_body "$name" "$type" "$address" "$TTL")"
        if curl --fail --silent --show-error --max-time 25 -X POST "${url}" \
            -H "Authorization: Bearer ${GODADDY_PAT}" \
            -H "Content-Type: application/json" --data "$body" >/dev/null; then
            log "Created ${type} ${name}.${zone} -> ${address}"
            rm -f "$all_file" "$type_file"
            return 0
        fi
        warn "Unable to create ${type} record for ${name}.${zone}."
        rm -f "$all_file" "$type_file"
        return 1
    fi

    if [[ "$count" != "1" || -z "$record_id" ]]; then
        warn "Multiple ${type} records exist for ${name}.${zone}; leaving them unchanged."
        rm -f "$all_file" "$type_file"
        return 1
    fi

    if [[ "$old_data" == "$address" ]]; then
        log "${type} ${name}.${zone} is already current."
        rm -f "$all_file" "$type_file"
        return 0
    fi

    [[ "$old_ttl" =~ ^[0-9]+$ ]] || old_ttl="$TTL"
    ((old_ttl >= 600 && old_ttl <= 86400)) || old_ttl="$TTL"
    body="$(json_body "$name" "$type" "$address" "$old_ttl")"
    encoded_id="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$record_id")"

    if curl --fail --silent --show-error --max-time 25 -X PUT "${url}/${encoded_id}" \
        -H "Authorization: Bearer ${GODADDY_PAT}" \
        -H "Content-Type: application/json" --data "$body" >/dev/null; then
        log "Updated ${type} ${name}.${zone}: ${old_data} -> ${address}"
        rm -f "$all_file" "$type_file"
        return 0
    fi

    warn "Unable to update ${type} record for ${name}.${zone}."
    rm -f "$all_file" "$type_file"
    return 1
}

failures=0
shopt -s nullglob
files=("${DDNS_DIR}"/*.conf)
shopt -u nullglob

if ((${#files[@]} == 0)); then
    log "No public DDNS records are configured."
    exit 0
fi

for file in "${files[@]}"; do
    unset DDNS_APP_ID DDNS_DOMAINS DDNS_ZONES
    source "$file"
    for index in "${!DDNS_DOMAINS[@]}"; do
        domain="${DDNS_DOMAINS[$index]}"
        zone="${DDNS_ZONES[$index]}"
        if [[ "$domain" == "$zone" ]]; then
            name="@"
        else
            name="${domain%.$zone}"
        fi
        if [[ -n "$ipv4" ]]; then
            reconcile_record "$zone" "$name" A "$ipv4" || failures=$((failures + 1))
        else
            warn "Skipping A update for ${domain}; no public IPv4 address is available."
            [[ -n "$ipv6" ]] || failures=$((failures + 1))
        fi
        if [[ -n "$ipv6" ]]; then
            reconcile_record "$zone" "$name" AAAA "$ipv6" || failures=$((failures + 1))
        fi
    done
done

if ((failures > 0)); then
    warn "DDNS update completed with ${failures} failed operation(s)."
    exit 1
fi

log "DDNS update completed."
