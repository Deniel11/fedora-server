#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora

# Git is NOT required by this setup. The repository can be downloaded with curl.
# If you want Git for repository development:
#   sudo dnf install -y git
#
# Docker itself is installed from Docker's official Fedora RPM repository.

dnf install -y dnf-plugins-core

if ! grep -Rqs 'download.docker.com/linux/fedora/docker-ce.repo' /etc/yum.repos.d 2>/dev/null; then
    dnf config-manager addrepo \
        --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo
fi

dnf install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable --now docker

docker version >/dev/null
docker compose version >/dev/null

log "Docker Engine and Compose are ready."
