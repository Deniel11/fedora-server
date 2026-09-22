#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
ensure_dirs

VW_DIR="${STACK_DIR}/docker/vaultwarden"
mkdir -p "${VW_DIR}/data"

cat > "${VW_DIR}/compose.yml" <<EOF
services:
  vaultwarden:
    image: \${VAULTWARDEN_IMAGE:-vaultwarden/server:latest}
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "https://${VAULTWARDEN_DOMAIN}"
      WEBSOCKET_ENABLED: "true"
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:${VAULTWARDEN_PORT}:80"
      - "127.0.0.1:${VAULTWARDEN_NOTIFICATIONS_HUB_PORT}:3012"
EOF

if docker inspect -f '{{.State.Running}}' vaultwarden 2>/dev/null | grep -qx true &&
   curl -fsS http://127.0.0.1:${VAULTWARDEN_PORT}/alive >/dev/null 2>&1; then
    log "Vaultwarden is already running and responding; skipping recreate."
    exit 0
fi

docker compose -f "${VW_DIR}/compose.yml" up -d

for _ in {1..30}; do
    if curl -fsS http://127.0.0.1:${VAULTWARDEN_PORT}/alive >/dev/null 2>&1; then
        log "Vaultwarden is responding on localhost:${VAULTWARDEN_PORT}."
        exit 0
    fi
    sleep 2
done

docker compose -f "${VW_DIR}/compose.yml" ps
die "Vaultwarden did not become ready."
