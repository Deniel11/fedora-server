#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
ensure_dirs

previous=""
if [[ -f "$PROXMOX_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$PROXMOX_STATE"
    previous="${PROXMOX_IP:-}"
fi

echo
echo "Proxmox is NOT proxied by Fedora Nginx."
echo "The Proxmox host keeps its own HTTPS service (normally TCP 8006)."
echo

read -r -p "Proxmox IPv4 address [${previous:-192.168.1.10}]: " PROXMOX_IP
PROXMOX_IP="${PROXMOX_IP:-${previous:-192.168.1.10}}"
valid_ipv4 "$PROXMOX_IP" || die "Invalid Proxmox IPv4 address."

cat > "$PROXMOX_STATE" <<EOF
PROXMOX_IP=$(printf '%q' "$PROXMOX_IP")
EOF
chmod 600 "$PROXMOX_STATE"

log "Saved Proxmox IP: ${PROXMOX_IP}"
