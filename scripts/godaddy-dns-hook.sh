#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/etc/fedora-server-setup"
CREDENTIALS_FILE="${STATE_DIR}/godaddy.ini"

API_BASE="https://api.godaddy.com/v3/domains/zones"

DNS_TTL="${GODADDY_DNS_TTL:-600}"
DNS_PROPAGATION_SECONDS="${GODADDY_DNS_PROPAGATION_SECONDS:-600}"

die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

log() {
    printf '\n[INFO] %s\n' "$*"
}

[[ -r "$CREDENTIALS_FILE" ]] ||
    die "Missing GoDaddy PAT file: $CREDENTIALS_FILE"

source "$CREDENTIALS_FILE"

[[ -n "${GODADDY_PAT:-}" ]] ||
    die "GODADDY_PAT is missing from $CREDENTIALS_FILE"

[[ -n "${CERTBOT_DOMAIN:-}" ]] ||
    die "CERTBOT_DOMAIN is not set"

[[ -n "${CERTBOT_VALIDATION:-}" ]] ||
    die "CERTBOT_VALIDATION is not set"

DOMAIN_STATE="${STATE_DIR}/domain.env"

[[ -r "$DOMAIN_STATE" ]] ||
    die "Missing domain state: $DOMAIN_STATE"

source "$DOMAIN_STATE"

BASE_DOMAIN="${BASE_DOMAIN:-}"

[[ -n "$BASE_DOMAIN" ]] ||
    die "BASE_DOMAIN is empty; public mode is required."

api() {
    curl \
        -fsS \
        --retry 3 \
        --retry-delay 2 \
        -H "Authorization: Bearer ${GODADDY_PAT}" \
        -H "Accept: application/json" \
        "$@"
}

record_name_for_domain() {
    local domain="$1"

    # ACME DNS-01 always publishes the validation TXT at
    # _acme-challenge.<zone>. Wildcard and non-wildcard identifiers for
    # the same zone intentionally use the same record name.
    domain="${domain#*.}"

    if [[ "$domain" == "$BASE_DOMAIN" || "$CERTBOT_DOMAIN" == "*.${BASE_DOMAIN}" ]]; then
        printf '_acme-challenge'
        return
    fi

    [[ "$domain" == *".${BASE_DOMAIN}" ]] ||
        die "Certificate domain $domain is outside BASE_DOMAIN=$BASE_DOMAIN"

    local prefix="${domain%.${BASE_DOMAIN}}"

    # For the application-zone wildcard, e.g. *.home.example.com,
    # the correct record is _acme-challenge.home.example.com.
    prefix="${prefix#*.}"
    prefix="${prefix#\*}"

    if [[ "$CERTBOT_DOMAIN" == "*."* ]]; then
        prefix="${CERTBOT_DOMAIN#*.}"
        prefix="${prefix%.${BASE_DOMAIN}}"
    fi

    if [[ -n "$prefix" ]]; then
        printf '_acme-challenge.%s' "$prefix"
    else
        printf '_acme-challenge'
    fi
}

upsert_txt_record() {
    local zone="$1"
    local name="$2"
    local validation="$3"

    local records existing_json payload

    records="$(
        api \
            -G \
            "${API_BASE}/${zone}/records/TXT/${name}" \
            2>/dev/null || printf '[]'
    )"

    existing_json="$(
        python3 - "$records" "$validation" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
wanted = sys.argv[2]

if isinstance(payload, dict):
    payload = [payload]

for item in payload:
    if item.get("type") == "TXT" and item.get("data") == wanted:
        print("present")
        break
PY
    )"

    if [[ "$existing_json" == "present" ]]; then
        return 0
    fi

    payload="$(
        python3 - "$name" "$validation" "$DNS_TTL" <<'PY'
import json
import sys

name, data, ttl = sys.argv[1], sys.argv[2], int(sys.argv[3])

print(json.dumps({
    "type": "TXT",
    "name": name,
    "data": data,
    "ttl": ttl
}))
PY
    )"

    api \
        -X POST \
        "${API_BASE}/${zone}/dns-records" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        >/dev/null
}

case "${1:-}" in

    auth)
        zone="$BASE_DOMAIN"
        name="$(record_name_for_domain "$CERTBOT_DOMAIN")"

        log "Creating GoDaddy TXT record ${name}.${zone}"

        upsert_txt_record "$zone" "$name" "$CERTBOT_VALIDATION"

        log "Waiting ${DNS_PROPAGATION_SECONDS}s for DNS propagation"
        sleep "$DNS_PROPAGATION_SECONDS"
        ;;

    cleanup)
        zone="$BASE_DOMAIN"
        name="$(record_name_for_domain "$CERTBOT_DOMAIN")"

        records="$(
            api \
                -G \
                "${API_BASE}/${zone}/dns-records" \
                --data-urlencode "type=TXT" \
                --data-urlencode "name=${name}" \
                --data-urlencode "page=1" \
                --data-urlencode "pageSize=100"
        )"

        mapfile -t record_ids < <(
            python3 - "$records" "$CERTBOT_VALIDATION" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
wanted = sys.argv[2]

for item in payload.get("items", []):
    if (
        item.get("type") == "TXT"
        and item.get("data") == wanted
        and item.get("recordId")
    ):
        print(item["recordId"])
PY
        )

        for record_id in "${record_ids[@]}"; do
            [[ -n "$record_id" ]] || continue

            log "Removing GoDaddy TXT record ${name}.${zone} (${record_id})"

            api \
                -X DELETE \
                "${API_BASE}/${zone}/dns-records/${record_id}" \
                >/dev/null || true
        done
        ;;

    *)
        die "Usage: $0 {auth|cleanup}"
        ;;

esac
