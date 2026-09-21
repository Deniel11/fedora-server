#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config

TLS_DIR="/etc/fedora-server-setup/tls"
COCKPIT_DIR="/etc/cockpit/ws-certs.d"

install -d -m 0755 "$COCKPIT_DIR"

rm -f "$COCKPIT_DIR/50-fedora-server.cert" "$COCKPIT_DIR/50-fedora-server.key"
ln -s "${TLS_DIR}/fedora-server.crt" "$COCKPIT_DIR/50-fedora-server.cert"
ln -s "${TLS_DIR}/fedora-server.key" "$COCKPIT_DIR/50-fedora-server.key"

chmod 600 "${TLS_DIR}/fedora-server.key"
chmod 644 "${TLS_DIR}/fedora-server.crt"

systemctl enable --now cockpit.socket
systemctl try-restart cockpit.socket || true

if command -v /usr/libexec/cockpit-certificate-ensure >/dev/null 2>&1; then
    /usr/libexec/cockpit-certificate-ensure --check || true
fi

log "Cockpit is available at https://${FEDORA_DOMAIN}:9090"
