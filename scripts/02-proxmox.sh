#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
validate_config
ensure_dirs

previous=""
if [[ -f "$PROXMOX_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$PROXMOX_STATE"
    previous="${PROXMOX_IP:-}"
fi

echo
echo "Proxmox is NOT proxied by Fedora Nginx."
echo "The Proxmox host keeps its own HTTPS service (normally TCP ${PROXMOX_PORT})."
echo

if [[ -n "$previous" ]]; then
    read -r -p "Current configured Proxmox IP: ${previous}"$'\n'"Is the current Proxmox IP address OK? [Y/n]: " keep
    keep="${keep:-Y}"
    if [[ "$keep" =~ ^[Yy]$ ]]; then
        PROXMOX_IP="$previous"
    else
        read -r -p "New Proxmox IPv4 address [${previous}]: " PROXMOX_IP
        PROXMOX_IP="${PROXMOX_IP:-$previous}"
    fi
else
    read -r -p "Proxmox IPv4 address [192.168.1.10]: " PROXMOX_IP
    PROXMOX_IP="${PROXMOX_IP:-192.168.1.10}"
fi

valid_ipv4 "$PROXMOX_IP" || die "Invalid Proxmox IPv4 address."

if [[ -n "$previous" && "$PROXMOX_IP" == "$previous" ]]; then
    log "Proxmox IP is unchanged; no update required."
    exit 0
fi

cat > "$PROXMOX_STATE" <<EOF_STATE
PROXMOX_IP=$(printf '%q' "$PROXMOX_IP")
EOF_STATE
chmod 600 "$PROXMOX_STATE"

log "Saved Proxmox IP: ${PROXMOX_IP}"
