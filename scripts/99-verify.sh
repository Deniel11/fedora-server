#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config

[[ -f "$NETWORK_STATE" ]] || die "Network state not found."
# shellcheck disable=SC1090
source "$NETWORK_STATE"

PROXMOX_IP="not-set"
if [[ -f "$PROXMOX_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$PROXMOX_STATE"
fi

echo
echo "========================================"
echo " Verification"
echo "========================================"

check() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '[ OK ] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
    fi
}

check "Docker service" systemctl is-active --quiet docker
check "Nginx service" systemctl is-active --quiet nginx
check "Cockpit socket" systemctl is-active --quiet cockpit.socket
check "Portainer container" docker inspect -f '{{.State.Running}}' portainer
check "Vaultwarden container" docker inspect -f '{{.State.Running}}' vaultwarden
check "Nginx configuration" nginx -t

curl -kfsS --resolve "${PORTAINER_DOMAIN}:443:${STATIC_IP}" \
    "https://${PORTAINER_DOMAIN}/" >/dev/null 2>&1 &&
    printf '[ OK ] Portainer HTTPS\n' ||
    printf '[WARN] Portainer HTTPS check failed\n'

curl -kfsS --resolve "${VAULTWARDEN_DOMAIN}:443:${STATIC_IP}" \
    "https://${VAULTWARDEN_DOMAIN}/alive" >/dev/null 2>&1 &&
    printf '[ OK ] Vaultwarden HTTPS\n' ||
    printf '[WARN] Vaultwarden HTTPS check failed\n'

echo
echo "========================================"
echo " Addresses"
echo "========================================"
echo "Fedora/Cockpit : https://${FEDORA_DOMAIN}:9090"
echo "Portainer      : https://${PORTAINER_DOMAIN}"
echo "Vaultwarden    : https://${VAULTWARDEN_DOMAIN}"
echo "Proxmox        : https://${PROXMOX_IP}:8006"
echo
echo "By IP before DNS is ready:"
echo "Cockpit        : https://${STATIC_IP}:9090"
echo "Portainer      : https://${STATIC_IP}"
echo "Vaultwarden    : https://${STATIC_IP}"
echo
echo "AdGuard records:"
echo "  ${FEDORA_DOMAIN} -> ${STATIC_IP}"
echo "  ${PORTAINER_DOMAIN} -> ${STATIC_IP}"
echo "  ${VAULTWARDEN_DOMAIN} -> ${STATIC_IP}"
echo "  ${PROXMOX_DOMAIN} -> ${PROXMOX_IP}"
echo
echo "Local CA:"
echo "  ${TLS_DIR}/ca.crt"
echo
warn "Import ca.crt into client trust stores to remove HTTPS trust warnings."
