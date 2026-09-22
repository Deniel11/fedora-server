#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora

if ! command -v dnf >/dev/null 2>&1; then
    die "dnf is not available."
fi

dnf install -y dnf-plugins-core

DOCKER_REPO="/etc/yum.repos.d/docker-ce.repo"
if [[ -f "$DOCKER_REPO" ]]; then
    log "Docker repository already exists, skipping repository setup."
else
    dnf config-manager addrepo \
        --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo
fi

if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker Engine and Compose are already working; skipping installation."
else
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if systemctl is-active --quiet docker; then
    log "Docker service is already running; skipping restart."
else
    systemctl enable --now docker
fi

docker version >/dev/null
docker compose version >/dev/null
log "Docker Engine and Compose are ready."
