#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

STATE_DIR="/etc/fedora-server-setup"
STATE_FILE="${STATE_DIR}/crowdsec-state.env"
ACQUIS_DIR="/etc/crowdsec/acquis.d"
ACQUIS_FILE="${ACQUIS_DIR}/fedora-server-nginx.yaml"
MANAGED_MARKER="# Managed by fedora-server CrowdSec module."

SERVICE_FILE="/etc/systemd/system/fedora-server-crowdsec-refresh.service"
TIMER_FILE="/etc/systemd/system/fedora-server-crowdsec-refresh.timer"

log()  { printf '[CrowdSec] %s\n' "$*"; }
warn() { printf '[CrowdSec] WARNING: %s\n' "$*" >&2; }
die()  { printf '[CrowdSec] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this command as root or with sudo."
}

require_fedora() {
    [[ -r /etc/os-release ]] || die "Cannot identify the operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "fedora" ]] || die "This integration targets Fedora Server."
}

CROWDSEC_DECISION="unset"
CROWDSEC_MANAGED_INSTALL="false"

load_state() {
    CROWDSEC_DECISION="unset"
    CROWDSEC_MANAGED_INSTALL="false"

    if [[ -f "$STATE_FILE" ]]; then
        # This file is root-owned and created by this script.
        # shellcheck disable=SC1090
        source "$STATE_FILE"
    fi
}

save_state() {
    install -d -m 0700 "$STATE_DIR"

    local temp
    temp="$(mktemp "${STATE_DIR}/.crowdsec-state.XXXXXX")"

    {
        printf 'CROWDSEC_DECISION=%q\n' "$CROWDSEC_DECISION"
        printf 'CROWDSEC_MANAGED_INSTALL=%q\n' "$CROWDSEC_MANAGED_INSTALL"
    } > "$temp"

    chmod 0600 "$temp"
    mv -f "$temp" "$STATE_FILE"
}

discover_nginx_logs() {
    command -v nginx >/dev/null 2>&1 ||
        die "Nginx is not installed."

    local dump
    dump="$(nginx -T 2>&1)" ||
        die "nginx -T failed. Fix the Nginx configuration first."

    # Parse active access_log directives printed by nginx -T.
    # Ignore comments, access_log off, syslog targets,
    # variables, relative paths, and non-file destinations.
    printf '%s\n' "$dump" |
        awk '
            {
                line = $0
                sub(/^[[:space:]]+/, "", line)

                if (line !~ /^access_log[[:space:]]+/) {
                    next
                }

                count = split(line, fields, /[[:space:]]+/)
                if (count < 2) {
                    next
                }

                target = fields[2]
                sub(/;.*/, "", target)
                gsub(/^["\047]|["\047]$/, "", target)

                if (target == "off" || target ~ /^syslog:/) {
                    next
                }

                if (target ~ /^\// && target !~ /\$/) {
                    print target
                }
            }
        ' |
        sort -u
}

write_acquisition() {
    local temp
    local log_path
    local count=0
    local -a logs=()

    command -v crowdsec >/dev/null 2>&1 ||
        die "CrowdSec is not installed. Run --install first."
    command -v cscli >/dev/null 2>&1 ||
        die "The cscli command is unavailable."

    mapfile -t logs < <(discover_nginx_logs)

    ((${#logs[@]} > 0)) ||
        die "No absolute file-based Nginx access_log paths were found."

    # Never overwrite an acquisition file belonging to another tool/user.
    if [[ -e "$ACQUIS_FILE" ]] &&
       ! grep -Fqx "$MANAGED_MARKER" "$ACQUIS_FILE"; then
        die "Refusing to overwrite unmanaged file: $ACQUIS_FILE"
    fi

    install -d -m 0750 "$ACQUIS_DIR"
    temp="$(mktemp "${ACQUIS_DIR}/.fedora-server-nginx.XXXXXX")"

    {
        printf '%s\n' "$MANAGED_MARKER"
        printf '%s\n' 'source: file'
        printf '%s\n' 'filenames:'

        for log_path in "${logs[@]}"; do
            if [[ "$log_path" == *[$'\n\r\t ']* ||
                  "$log_path" == *'"'* ||
                  "$log_path" == *'\'* ]]; then
                warn "Skipping an unsupported log path: $log_path"
                continue
            fi

            printf '  - "%s"\n' "$log_path"
            ((count += 1))
        done

        printf '%s\n' \
            'labels:' \
            '  type: nginx'
    } > "$temp"

    if ((count == 0)); then
        rm -f "$temp"
        die "No supported Nginx access log paths were found."
    fi

    chmod 0640 "$temp"

    local backup=""
    if [[ -f "$ACQUIS_FILE" ]]; then
        backup="$(mktemp "${ACQUIS_DIR}/.fedora-server-nginx-backup.XXXXXX")"
        cp -p "$ACQUIS_FILE" "$backup"
    fi

    if [[ -f "$ACQUIS_FILE" ]] && cmp -s "$temp" "$ACQUIS_FILE"; then
        rm -f "$temp"
        [[ -n "$backup" ]] && rm -f "$backup"
        log "Nginx acquisition configuration is unchanged."
        return 0
    fi

    mv -f "$temp" "$ACQUIS_FILE"

    if ! crowdsec -t; then
        warn "CrowdSec validation failed; restoring the previous acquisition file."
        if [[ -n "$backup" ]]; then
            mv -f "$backup" "$ACQUIS_FILE"
        else
            rm -f "$ACQUIS_FILE"
        fi
        die "Generated CrowdSec configuration was rejected."
    fi

    [[ -n "$backup" ]] && rm -f "$backup"

    cscli collections install crowdsecurity/nginx

    systemctl enable crowdsec
    systemctl restart crowdsec
    systemctl is-active --quiet crowdsec ||
        die "CrowdSec did not become active."

    log "CrowdSec is monitoring these configured Nginx log paths:"
    printf '  - %s\n' "${logs[@]}"
}

install_refresh_timer() {
    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Refresh CrowdSec Nginx log discovery for Fedora Server
After=network-online.target crowdsec.service nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/crowdsec.sh --refresh
EOF_SERVICE

    cat > "$TIMER_FILE" <<'EOF_TIMER'
[Unit]
Description=Periodically refresh CrowdSec Nginx log discovery

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER

    chmod 0644 "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload
    systemctl enable --now fedora-server-crowdsec-refresh.timer
}

install_crowdsec() {
    load_state

    local previous_managed="${CROWDSEC_MANAGED_INSTALL:-false}"
    local was_installed=false

    if command -v crowdsec >/dev/null 2>&1 &&
       command -v cscli >/dev/null 2>&1; then
        was_installed=true
        log "An existing CrowdSec installation was detected."
    else
        log "Installing CrowdSec from its official RPM repository."
        warn "The official repository bootstrap downloads and executes a script as root."

        read -r -p "Continue with the official CrowdSec repository bootstrap? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || {
            log "CrowdSec installation cancelled."
            return 0
        }

        command -v curl >/dev/null 2>&1 ||
            die "curl is required to bootstrap the CrowdSec repository."

        curl -fsSL https://install.crowdsec.net | sh ||
            die "CrowdSec repository bootstrap failed."

        dnf install -y crowdsec ||
            die "CrowdSec package installation failed."
    fi

    write_acquisition
    install_refresh_timer

    CROWDSEC_DECISION="installed"
    if [[ "$was_installed" == true ]]; then
        CROWDSEC_MANAGED_INSTALL="$previous_managed"
    else
        CROWDSEC_MANAGED_INSTALL="true"
    fi
    save_state

    log "CrowdSec detection is configured. No bouncer or automatic blocking was enabled."
}

refresh_crowdsec() {
    command -v nginx >/dev/null 2>&1 ||
        die "Nginx is not available for log discovery."
    command -v crowdsec >/dev/null 2>&1 ||
        die "CrowdSec is not installed."

    write_acquisition
}

show_status() {
    load_state

    printf '\nCrowdSec integration status\n'
    printf 'Saved decision: %s\n' "$CROWDSEC_DECISION"
    printf 'Installed by this module: %s\n' "$CROWDSEC_MANAGED_INSTALL"

    if command -v crowdsec >/dev/null 2>&1; then
        systemctl is-active crowdsec 2>/dev/null || true
        cscli collections list 2>/dev/null || true
        cscli metrics 2>/dev/null || true
    else
        printf 'CrowdSec package: not detected\n'
    fi

    if [[ -f "$ACQUIS_FILE" ]]; then
        printf '\nManaged Nginx acquisition file: %s\n' "$ACQUIS_FILE"
        cat "$ACQUIS_FILE"
    fi
}

remove_integration() {
    if [[ -f "$ACQUIS_FILE" ]] &&
       grep -Fqx "$MANAGED_MARKER" "$ACQUIS_FILE"; then
        rm -f "$ACQUIS_FILE"
    fi

    systemctl disable --now fedora-server-crowdsec-refresh.timer 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload

    if command -v crowdsec >/dev/null 2>&1; then
        if crowdsec -t; then
            systemctl restart crowdsec || true
        else
            warn "CrowdSec validation failed after removing this module's file."
            warn "Review /etc/crowdsec/acquis.d before restarting CrowdSec."
        fi
    fi

    rm -f "$STATE_FILE"
    log "The Fedora Server integration has been removed."
    log "The CrowdSec package and other CrowdSec configuration were left untouched."
}

offer_install() {
    load_state

    case "$CROWDSEC_DECISION" in
        installed)
            log "CrowdSec was previously configured; skipping the install prompt."
            return 0
            ;;
        declined)
            log "CrowdSec was previously declined; skipping the install prompt."
            log "To install later, run: sudo bash scripts/crowdsec.sh --install"
            return 0
            ;;
    esac

    cat <<'EOF'
Optional CrowdSec integration

CrowdSec will inspect the configured host Nginx access logs.
This enables detection only. It does not automatically block IP addresses.
A separate decision is required before configuring any bouncer or firewall action.
EOF

    read -r -p "Install and configure CrowdSec now? [y/N] " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        install_crowdsec
    else
        CROWDSEC_DECISION="declined"
        save_state
        log "Skipped. You can install CrowdSec later with --install."
    fi
}

main() {
    require_root
    require_fedora

    case "${1:-menu}" in
        --offer)   offer_install ;;
        --install) install_crowdsec ;;
        --refresh) refresh_crowdsec ;;
        --status)  show_status ;;
        --remove)  remove_integration ;;
        menu)
            printf '\nCrowdSec management\n'
            printf '1) Install or configure\n'
            printf '2) Refresh Nginx log discovery\n'
            printf '3) Show status\n'
            printf '4) Remove this integration\n'
            printf '5) Exit\n'
            read -r -p "Select an option: " choice
            case "$choice" in
                1) install_crowdsec ;;
                2) refresh_crowdsec ;;
                3) show_status ;;
                4) remove_integration ;;
                5) exit 0 ;;
                *) die "Invalid menu option." ;;
            esac
            ;;
        *)
            die "Usage: $0 [--offer|--install|--refresh|--status|--remove]"
            ;;
    esac
}

main "$@"
