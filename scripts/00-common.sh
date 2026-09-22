#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/domains.conf"
STATE_DIR="/etc/fedora-server-setup"
TLS_DIR="${STATE_DIR}/tls"
NETWORK_STATE="${STATE_DIR}/network.env"
PROXMOX_STATE="${STATE_DIR}/proxmox.env"
STACK_DIR="/opt/fedora-server-setup"

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this installer as root, for example: sudo ./install.sh"
}

require_fedora() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    source /etc/os-release
    [[ "${ID:-}" == "fedora" ]] || die "This repository supports Fedora Server only. Detected: ${ID:-unknown}"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Missing config: $CONFIG_FILE"

    local config_vars
    config_vars=$(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$CONFIG_FILE" \
        | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*).*/\1/')

    source "$CONFIG_FILE"

    local var
    for var in $config_vars; do
        [[ -n "${!var:-}" ]] || die "$var is not set"
    done
}

run_stage() {
    local stage="$1"
    log "Running ${stage}"
    bash "${REPO_ROOT}/scripts/${stage}"
}

valid_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

valid_prefix() {
    local p="$1"
    [[ "$p" =~ ^[0-9]{1,2}$ ]] && (( p >= 1 && p <= 32 ))
}

valid_hostname() {
    local h="$1"
    [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

ensure_dirs() {
    install -d -m 0750 "$STATE_DIR" "$TLS_DIR" "$STACK_DIR"
}
