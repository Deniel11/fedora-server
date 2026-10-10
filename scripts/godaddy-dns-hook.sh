#!/usr/bin/env bash

set -Eeuo pipefail

STATE_DIR="/etc/fedora-server-setup"
CREDENTIALS_FILE="${STATE_DIR}/godaddy.ini"
DOMAIN_STATE="${STATE_DIR}/domain.env"
ZONE_CONFIG="${STATE_DIR}/godaddy-zones.conf"

API_BASE="https://api.godaddy.com/v3/domains/zones"
DNS_TTL="${GODADDY_DNS_TTL:-600}"
DNS_PROPAGATION_SECONDS="${GODADDY_DNS_PROPAGATION_SECONDS:-60}"

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

[[ -r "$DOMAIN_STATE" ]] ||
    die "Missing domain state: $DOMAIN_STATE"

source "$DOMAIN_STATE"

BASE_DOMAIN="${BASE_DOMAIN:-}"

[[ -n "$BASE_DOMAIN" ]] ||
    die "BASE_DOMAIN is empty; public mode is required."

GODADDY_DNS_ZONES=()

if [[ -r "$ZONE_CONFIG" ]]; then
    source "$ZONE_CONFIG"
fi

if ((${#GODADDY_DNS_ZONES[@]} == 0)) && [[ -n "${BASE_DOMAIN:-}" ]]; then
    GODADDY_DNS_ZONES=("$BASE_DOMAIN")
fi

[[ -n "${CERTBOT_DOMAIN:-}" ]] ||
    die "CERTBOT_DOMAIN is not set"

[[ -n "${CERTBOT_VALIDATION:-}" ]] ||
    die "CERTBOT_VALIDATION is not set"

api_error() {
    case "$1" in
        401)
            die "GoDaddy API returned HTTP 401: the stored PAT is invalid, expired, revoked, or malformed. Create a new PAT and replace /etc/fedora-server-setup/godaddy.ini."
            ;;
        403)
            die "GoDaddy API returned HTTP 403: the PAT is valid but lacks required permissions. Grant domains.domain:read and domains.dns:update."
            ;;
        404)
            die "GoDaddy API returned HTTP 404: verify that ${BASE_DOMAIN} is hosted on GoDaddy authoritative DNS and accessible to this account."
            ;;
        *)
            die "GoDaddy API request failed with HTTP $1: $2"
            ;;
    esac
}

request() {
    local method="$1"
    shift

    local response_file
    local status
    local body

    response_file="$(mktemp)"

    status="$(
        curl \
            -sS \
            -o "$response_file" \
            -w '%{http_code}' \
            --request "$method" \
            --retry 3 \
            --retry-delay 2 \
            --connect-timeout 10 \
            --max-time 30 \
            -H "Authorization: Bearer ${GODADDY_PAT}" \
            -H 'Accept: application/json' \
            "$@"
    )"

    if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
        body="$(cat "$response_file")"
        rm -f "$response_file"
        api_error "$status" "$body"
    fi

    cat "$response_file"
    rm -f "$response_file"
}


find_zone() {
    local domain="${1%.}"
    local candidate
    local best=""

    for candidate in "${GODADDY_DNS_ZONES[@]}"; do
        candidate="${candidate%.}"
        [[ -n "$candidate" ]] || continue

        if [[ "$domain" == "$candidate" || "$domain" == *".${candidate}" ]]; then
            if ((${#candidate} > ${#best})); then
                best="$candidate"
            fi
        fi
    done

    [[ -n "$best" ]] ||
        die "No configured GoDaddy DNS zone matches ${domain}. Add its registered zone to ${ZONE_CONFIG}."

    printf '%s' "$best"
}

record_name() {
    local domain="${1%.}"
    local zone="${2%.}"
    local relative_name

    if [[ "$domain" == "$zone" ]]; then
        printf '_acme-challenge'
        return
    fi

    [[ "$domain" == *".${zone}" ]] ||
        die "Domain ${domain} is not inside DNS zone ${zone}."

    relative_name="${domain%."${zone}"}"
    relative_name="${relative_name%.}"

    [[ -n "$relative_name" ]] ||
        die "Could not derive the relative DNS name for ${domain}."

    printf '_acme-challenge.%s' "$relative_name"
}

preflight() {
    local zone="$1"

    log "Checking GoDaddy API access for ${zone}"

    request \
        GET \
        "${API_BASE}/${zone}/dns-records?type=TXT&name=_acme-challenge&page=1&pageSize=1" \
        >/dev/null

    log "GoDaddy API authentication and DNS read access are working for ${zone}."
}

find_record() {
    local zone="$1"
    local name="$2"
    local wanted="$3"
    local response

    response="$(
        request \
            GET \
            "${API_BASE}/${zone}/dns-records?type=TXT&name=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=""))' "$name")&page=1&pageSize=100"
    )"

    python3 - "$response" "$wanted" <<'PY'
import json
import sys

for item in json.loads(sys.argv[1]).get("items", []):
    if item.get("type") == "TXT" and item.get("data") == sys.argv[2]:
        print(item.get("recordId", ""))
        break
PY
}

add_record() {
    local zone="$1"
    local name="$2"
    local value="$3"
    local payload

    payload="$(
        python3 - "$name" "$value" "$DNS_TTL" <<'PY'
import json
import sys

print(
    json.dumps(
        {
            "type": "TXT",
            "name": sys.argv[1],
            "data": sys.argv[2],
            "ttl": int(sys.argv[3]),
        }
    )
)
PY
    )"

    request \
        POST \
        "${API_BASE}/${zone}/dns-records" \
        -H 'Content-Type: application/json' \
        --data "$payload" \
        >/dev/null
}

delete_record() {
    request \
        DELETE \
        "${API_BASE}/$1/dns-records/$2" \
        >/dev/null
}

case "${1:-}" in
    auth)
        zone="$(find_zone "$CERTBOT_DOMAIN")"
        name="$(record_name "$CERTBOT_DOMAIN" "$zone")"

        preflight "$zone"

        log "Creating GoDaddy TXT record ${name}.${zone}"

        existing="$(
            find_record \
                "$zone" \
                "$name" \
                "$CERTBOT_VALIDATION" ||
            true
        )"

        if [[ -z "$existing" ]]; then
            add_record \
                "$zone" \
                "$name" \
                "$CERTBOT_VALIDATION"
        fi

        log "Waiting ${DNS_PROPAGATION_SECONDS}s for DNS propagation"

        sleep "$DNS_PROPAGATION_SECONDS"
        ;;

    cleanup)
        zone="$(find_zone "$CERTBOT_DOMAIN")"
        name="$(record_name "$CERTBOT_DOMAIN" "$zone")"

        existing="$(
            find_record \
                "$zone" \
                "$name" \
                "$CERTBOT_VALIDATION" ||
            true
        )"

        if [[ -n "$existing" ]]; then
            log "Removing GoDaddy TXT record ${name}.${zone} (${existing})"

            delete_record \
                "$zone" \
                "$existing"
        fi
        ;;

    *)
        die "Usage: $0 {auth|cleanup}"
        ;;
esac