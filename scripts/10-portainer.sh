#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
ensure_dirs

PORTAINER_DIR="${STACK_DIR}/docker/portainer"
mkdir -p "$PORTAINER_DIR"

cat > "${PORTAINER_DIR}/compose.yml" <<'EOF'
services:
  portainer:
    image: ${PORTAINER_IMAGE:-portainer/portainer-ce:latest}
    container_name: portainer
    restart: unless-stopped
    ports:
      - "127.0.0.1:9443:9443"
    volumes:
      - portainer_data:/data
      - /var/run/docker.sock:/var/run/docker.sock
volumes:
  portainer_data:
EOF

docker compose -f "${PORTAINER_DIR}/compose.yml" up -d

for _ in {1..30}; do
    if curl -kfsS https://127.0.0.1:9443/ >/dev/null 2>&1; then
        log "Portainer is responding on localhost:9443."
        exit 0
    fi
    sleep 2
done

docker compose -f "${PORTAINER_DIR}/compose.yml" ps
die "Portainer did not become ready."
