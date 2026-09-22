#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config

[[ -f "$NETWORK_STATE" ]] || die "Network state not found."
source "$NETWORK_STATE"

PROXMOX_IP="not-set"
if [[ -f "$PROXMOX_STATE" ]]; then
    source "$PROXMOX_STATE"
fi

echo
echo "========================================"
echo " Verification"
echo "========================================"

FAILURES=0
check() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '[ OK ] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

check "Docker service" systemctl is-active --quiet docker
check "Nginx service" systemctl is-active --quiet nginx
check "Cockpit socket" systemctl is-active --quiet cockpit.socket
check "Portainer container" docker inspect -f '{{.State.Running}}' portainer
check "Vaultwarden container" docker inspect -f '{{.State.Running}}' vaultwarden
check "Nginx configuration" nginx -t
check "Joplin container" docker inspect -f '{{.State.Running}}' joplin
check "Joplin PostgreSQL container" docker inspect -f '{{.State.Running}}' joplin-postgres

if curl -kfsS --resolve "${PORTAINER_DOMAIN}:443:${STATIC_IP}" \
    "https://${PORTAINER_DOMAIN}/" >/dev/null 2>&1; then
    printf '[ OK ] Portainer HTTPS\n'
else
    printf '[FAIL] Portainer HTTPS check failed\n'
    FAILURES=$((FAILURES + 1))
fi

if curl -kfsS --resolve "${VAULTWARDEN_DOMAIN}:443:${STATIC_IP}" \
    "https://${VAULTWARDEN_DOMAIN}/alive" >/dev/null 2>&1; then
    printf '[ OK ] Vaultwarden HTTPS\n'
else
    printf '[FAIL] Vaultwarden HTTPS check failed\n'
    FAILURES=$((FAILURES + 1))
fi

if curl -kfsS --resolve "${JOPLIN_DOMAIN}:443:${STATIC_IP}" \
    "https://${JOPLIN_DOMAIN}/" >/dev/null 2>&1; then
    printf '[ OK ] Joplin HTTPS\n'
else
    printf '[FAIL] Joplin HTTPS check failed\n'
    FAILURES=$((FAILURES + 1))
fi

echo
echo "========================================"
echo " Addresses"
echo "========================================"
echo "Proxmox        : https://${PROXMOX_IP}:${PROXMOX_PORT}"
echo "Fedora/Cockpit : https://${FEDORA_DOMAIN}:${FEDORA_PORT}"
echo "Portainer      : https://${PORTAINER_DOMAIN}"
echo "Vaultwarden    : https://${VAULTWARDEN_DOMAIN}"
echo "Joplin         : https://${JOPLIN_DOMAIN}"
echo
echo "By IP before DNS is ready:"
echo "Cockpit        : https://${STATIC_IP}:${FEDORA_PORT}"
echo "Portainer      : https://${STATIC_IP}"
echo "Vaultwarden    : https://${STATIC_IP}"
echo "Joplin         : https://${STATIC_IP}"
echo
echo "AdGuard records:"
echo "  ${FEDORA_DOMAIN} -> ${STATIC_IP}"
echo "  ${PORTAINER_DOMAIN} -> ${STATIC_IP}"
echo "  ${VAULTWARDEN_DOMAIN} -> ${STATIC_IP}"
echo "  ${PROXMOX_DOMAIN} -> ${PROXMOX_IP}"
echo "  ${JOPLIN_DOMAIN} -> ${STATIC_IP}"
echo
echo "Local CA:"
echo "  ${TLS_DIR}/ca.crt"
echo
warn "Import ca.crt into client trust stores to remove HTTPS trust warnings."

if (( FAILURES > 0 )); then
    printf '\n[ERROR] Verification failed: %d check(s) failed.\n' "$FAILURES" >&2
    exit 1
fi

printf '\n[ OK ] All critical verification checks passed.\n'
