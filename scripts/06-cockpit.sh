#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config

TLS_DIR="/etc/fedora-server-setup/tls"
COCKPIT_DIR="/etc/cockpit/ws-certs.d"
install -d -m 0755 "$COCKPIT_DIR"

cert_link="$COCKPIT_DIR/50-fedora-server.cert"
key_link="$COCKPIT_DIR/50-fedora-server.key"

[[ -L "$cert_link" && "$(readlink "$cert_link")" == "${TLS_DIR}/fedora-server.crt" ]] ||
    ln -sfn "${TLS_DIR}/fedora-server.crt" "$cert_link"
[[ -L "$key_link" && "$(readlink "$key_link")" == "${TLS_DIR}/fedora-server.key" ]] ||
    ln -sfn "${TLS_DIR}/fedora-server.key" "$key_link"

chmod 600 "${TLS_DIR}/fedora-server.key"
chmod 644 "${TLS_DIR}/fedora-server.crt"

if systemctl is-active --quiet cockpit.socket; then
    log "Cockpit socket is already active; skipping restart."
else
    systemctl enable --now cockpit.socket
fi

if command -v /usr/libexec/cockpit-certificate-ensure >/dev/null 2>&1; then
    /usr/libexec/cockpit-certificate-ensure --check || true
fi

log "Cockpit is available at https://${FEDORA_DOMAIN}:${FEDORA_PORT}"
