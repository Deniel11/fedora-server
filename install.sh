#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"

require_root
require_fedora
load_config

log "Fedora Server Home Services Setup"
log "Repository: ${SCRIPT_DIR}"

# Updating first is deliberate. If the base OS can be updated, do that before
# installing the rest of the stack, then stop so the operator can reboot if needed.
if dnf -q check-update >/dev/null 2>&1; then
    log "No pending package updates detected."
else
    rc=$?
    if [[ "$rc" -eq 100 ]]; then
        warn "Fedora has pending updates."
        read -r -p "Install all available updates now and stop the installer? [Y/n]: " answer
        answer="${answer:-Y}"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            dnf upgrade -y
            echo
            log "System update completed."
            warn "If Fedora requests a reboot, reboot now."
            warn "Then run sudo ./install.sh again."
            exit 0
        fi
        die "Installation cannot continue while updates are pending."
    fi
    die "Unable to determine Fedora update state (dnf check-update exit code: ${rc})."
fi

run_stage "01-system.sh"
run_stage "02-proxmox.sh"
run_stage "03-network.sh"
run_stage "04-docker.sh"
run_stage "40-certificates.sh"
run_stage "05-nginx.sh"
run_stage "06-cockpit.sh"
run_stage "10-portainer.sh"
run_stage "20-vaultwarden.sh"
run_stage "30-joplin.sh"
run_stage "99-verify.sh"

log "Installation completed."
