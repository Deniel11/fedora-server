#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="/etc/fedora-server-setup"
CREDENTIALS_FILE="${STATE_DIR}/godaddy.ini"
DOMAIN_STATE="${STATE_DIR}/domain.env"
API_BASE="https://api.godaddy.com/v3/domains/zones"
DNS_TTL="${GODADDY_DNS_TTL:-600}"
DNS_PROPAGATION_SECONDS="${GODADDY_DNS_PROPAGATION_SECONDS:-60}"
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
log(){ printf '\n[INFO] %s\n' "$*"; }
[[ -r "$CREDENTIALS_FILE" ]] || die "Missing GoDaddy PAT file: $CREDENTIALS_FILE"
source "$CREDENTIALS_FILE"
[[ -n "${GODADDY_PAT:-}" ]] || die "GODADDY_PAT is missing from $CREDENTIALS_FILE"
[[ -r "$DOMAIN_STATE" ]] || die "Missing domain state: $DOMAIN_STATE"
source "$DOMAIN_STATE"
BASE_DOMAIN="${BASE_DOMAIN:-}"; [[ -n "$BASE_DOMAIN" ]] || die 'BASE_DOMAIN is empty; public mode is required.'
[[ -n "${CERTBOT_DOMAIN:-}" ]] || die 'CERTBOT_DOMAIN is not set'
[[ -n "${CERTBOT_VALIDATION:-}" ]] || die 'CERTBOT_VALIDATION is not set'
api_error(){ case "$1" in 401) die 'GoDaddy API returned HTTP 401: the stored PAT is invalid, expired, revoked, or malformed. Create a new PAT and replace /etc/fedora-server-setup/godaddy.ini.';;403) die 'GoDaddy API returned HTTP 403: the PAT is valid but lacks required permissions. Grant domains.domain:read and domains.dns:update.';;404) die "GoDaddy API returned HTTP 404: verify that ${BASE_DOMAIN} is hosted on GoDaddy authoritative DNS and accessible to this account.";;*) die "GoDaddy API request failed with HTTP $1: $2";;esac; }
request(){ local method="$1"; shift; local f status; f="$(mktemp)"; status="$(curl -sS -o "$f" -w '%{http_code}' --request "$method" --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 -H "Authorization: Bearer ${GODADDY_PAT}" -H 'Accept: application/json' "$@")"; if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then local body; body="$(cat "$f")"; rm -f "$f"; api_error "$status" "$body"; fi; cat "$f"; rm -f "$f"; }
record_name(){ local d="$1" rel; d="${d#*.}"; if [[ "$d" == "$BASE_DOMAIN" ]]; then printf '_acme-challenge'; return; fi; [[ "$d" == *".${BASE_DOMAIN}" ]] || die "Certificate domain $d is outside BASE_DOMAIN=$BASE_DOMAIN"; rel="${d%.${BASE_DOMAIN}}"; rel="${rel%.}"; [[ -n "$rel" ]] && printf '_acme-challenge.%s' "$rel" || printf '_acme-challenge'; }
preflight(){ log "Checking GoDaddy API access for ${BASE_DOMAIN}"; request GET "${API_BASE}/${BASE_DOMAIN}/dns-records?type=TXT&name=_acme-challenge&page=1&pageSize=1" >/dev/null; log 'GoDaddy API authentication and DNS read access are working.'; }
find_record(){ local zone="$1" name="$2" wanted="$3" response; response="$(request GET "${API_BASE}/${zone}/dns-records?type=TXT&name=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=""))' "$name")&page=1&pageSize=100")"; python3 - "$response" "$wanted" <<'PY'
import json,sys
for item in json.loads(sys.argv[1]).get('items',[]):
    if item.get('type')=='TXT' and item.get('data')==sys.argv[2]:
        print(item.get('recordId','')); break
PY
}
add_record(){ local zone="$1" name="$2" value="$3" payload; payload="$(python3 - "$name" "$value" "$DNS_TTL" <<'PY'
import json,sys
print(json.dumps({'type':'TXT','name':sys.argv[1],'data':sys.argv[2],'ttl':int(sys.argv[3])}))
PY
)"; request POST "${API_BASE}/${zone}/dns-records" -H 'Content-Type: application/json' --data "$payload" >/dev/null; }
delete_record(){ request DELETE "${API_BASE}/$1/dns-records/$2" >/dev/null; }
case "${1:-}" in
 auth) zone="$BASE_DOMAIN"; name="$(record_name "$CERTBOT_DOMAIN")"; preflight; log "Creating GoDaddy TXT record ${name}.${zone}"; existing="$(find_record "$zone" "$name" "$CERTBOT_VALIDATION" || true)"; [[ -n "$existing" ]] || add_record "$zone" "$name" "$CERTBOT_VALIDATION"; log "Waiting ${DNS_PROPAGATION_SECONDS}s for DNS propagation"; sleep "$DNS_PROPAGATION_SECONDS";;
 cleanup) zone="$BASE_DOMAIN"; name="$(record_name "$CERTBOT_DOMAIN")"; existing="$(find_record "$zone" "$name" "$CERTBOT_VALIDATION" || true)"; [[ -n "$existing" ]] && { log "Removing GoDaddy TXT record ${name}.${zone} (${existing})"; delete_record "$zone" "$existing"; };;
 *) die "Usage: $0 {auth|cleanup}";;
esac
