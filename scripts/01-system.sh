#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
ensure_dirs

log "Installing base packages"

dnf install -y \
    ca-certificates \
    curl \
    firewalld \
    openssl \
    tar \
    unzip \
    policycoreutils-python-utils \
    nginx \
    cockpit

systemctl enable --now firewalld

# Nginx will terminate HTTP/HTTPS. Cockpit remains directly reachable on 9090.
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-service=cockpit
firewall-cmd --reload

log "Base system preparation complete."
