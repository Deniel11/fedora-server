#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
ensure_dirs

log "Installing base packages"
dnf install -y \
    ca-certificates curl firewalld openssl tar unzip \
    policycoreutils-python-utils nginx cockpit

systemctl enable --now firewalld

changed=0
for service in http https cockpit; do
    if ! firewall-cmd --permanent --query-service="$service" >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service="$service"
        changed=1
    fi
done

if (( changed )); then
    firewall-cmd --reload
else
    log "Firewall rules already configured; skipping reload."
fi

log "Base system preparation complete."
