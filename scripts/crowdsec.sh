#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR=/etc/fedora-server-setup
STATE_FILE="${STATE_DIR}/crowdsec-state.env"
ACQUIS_DIR=/etc/crowdsec/acquis.d
ACQUIS_FILE="${ACQUIS_DIR}/fedora-server-nginx.yaml"
MARKER="# Managed by fedora-server CrowdSec module."
STACK_DIR=/opt/fedora-server-setup
INSTALLED_SCRIPT="${STACK_DIR}/crowdsec.sh"
SERVICE_FILE=/etc/systemd/system/fedora-server-crowdsec-refresh.service
TIMER_FILE=/etc/systemd/system/fedora-server-crowdsec-refresh.timer

log(){ printf '[CrowdSec] %s\n' "$*"; }
warn(){ printf '[CrowdSec] WARNING: %s\n' "$*" >&2; }
die(){ printf '[CrowdSec] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo or as root."
[[ -r /etc/os-release ]] || die "Cannot identify operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == fedora ]] || die "Fedora Server is required."

DECISION=unset
MANAGED_INSTALL=false

load_state(){
    DECISION=unset
    MANAGED_INSTALL=false
    if [[ -f $STATE_FILE ]]; then
        [[ $(stat -c %U "$STATE_FILE") == root ]] || die "State file is not root-owned."
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        DECISION="${CROWDSEC_DECISION:-unset}"
        MANAGED_INSTALL="${CROWDSEC_MANAGED_INSTALL:-false}"
    fi
}
save_state(){
    install -d -o root -g root -m 0700 "$STATE_DIR"
    local tmp
    tmp=$(mktemp "${STATE_DIR}/.crowdsec-state.XXXXXX")
    printf 'CROWDSEC_DECISION=%q\nCROWDSEC_MANAGED_INSTALL=%q\n' \
        "$DECISION" "$MANAGED_INSTALL" > "$tmp"
    chown root:root "$tmp"; chmod 0600 "$tmp"; mv -f "$tmp" "$STATE_FILE"
}

discover_logs(){
    command -v nginx >/dev/null 2>&1 || { warn "Nginx is not installed."; return 1; }
    local dump
    dump=$(nginx -T 2>&1) || { warn "nginx -T failed; fix Nginx configuration."; return 1; }

    printf '%s\n' "$dump" | awk '
      function trim(s){sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s}
      {
        line=trim($0)
        if(line !~ /^access_log[ \t]+/) next
        sub(/^access_log[ \t]+/,"",line)
        target=""
        q=substr(line,1,1)
        if(q=="\"" || q=="\047"){
          rest=substr(line,2); esc=0
          for(i=1;i<=length(rest);i++){
            c=substr(rest,i,1)
            if(c==q && !esc){target=substr(rest,1,i-1); break}
            if(c=="\\" && !esc) esc=1; else esc=0
          }
          if(target=="") next
        } else {
          sub(/[; \t].*$/,"",line); target=line
        }
        if(target=="off" || target ~ /^syslog:/ || target !~ /^\//) next
        gsub(/\$\{[A-Za-z_][A-Za-z0-9_]*\}/,"*",target)
        gsub(/\$[A-Za-z_][A-Za-z0-9_]*/,"*",target)
        gsub(/\$[0-9]+/,"*",target)
        if(target ~ /[\r\n]/) next
        print target
      }' | sort -u
}

ensure_collection(){
    if ! cscli collections list 2>/dev/null | grep -Fq 'crowdsecurity/nginx'; then
        cscli collections install crowdsecurity/nginx ||
            die "Could not install crowdsecurity/nginx collection."
    fi
}

write_acquisition(){
    command -v crowdsec >/dev/null 2>&1 || die "CrowdSec is not installed."
    command -v cscli >/dev/null 2>&1 || die "cscli is unavailable."
    local discovered
    discovered=$(discover_logs) || die "Nginx log discovery failed."
    [[ -n $discovered ]] || die "No supported absolute Nginx access_log paths found."
    local -a logs=()
    mapfile -t logs <<< "$discovered"

    if [[ -e $ACQUIS_FILE ]] && ! grep -Fqx "$MARKER" "$ACQUIS_FILE"; then
        die "Refusing to overwrite unmanaged file: $ACQUIS_FILE"
    fi
    install -d -o root -g root -m 0750 "$ACQUIS_DIR"
    local tmp backup="" path
    tmp=$(mktemp "${ACQUIS_DIR}/.fedora-server-nginx.XXXXXX")
    {
        printf '%s\nsource: file\nfilenames:\n' "$MARKER"
        for path in "${logs[@]}"; do
            [[ -n $path ]] || continue
            path="${path//\'/\'\'}"
            printf "  - '%s'\n" "$path"
        done
        printf '%s\n' 'discovery_poll_enable: true' \
            'discovery_poll_interval: 30s' 'labels:' '  type: nginx'
    } > "$tmp"
    chmod 0640 "$tmp"

    if [[ -f $ACQUIS_FILE ]] && cmp -s "$tmp" "$ACQUIS_FILE"; then
        rm -f "$tmp"
        log "Acquisition configuration unchanged."
    else
        if [[ -f $ACQUIS_FILE ]]; then
            backup=$(mktemp "${ACQUIS_DIR}/.fedora-server-nginx-backup.XXXXXX")
            cp -p "$ACQUIS_FILE" "$backup"
        fi
        mv -f "$tmp" "$ACQUIS_FILE"
        if ! crowdsec -t; then
            warn "Invalid generated configuration; restoring previous file."
            if [[ -n $backup ]]; then mv -f "$backup" "$ACQUIS_FILE"; else rm -f "$ACQUIS_FILE"; fi
            die "CrowdSec configuration validation failed."
        fi
        [[ -n $backup ]] && rm -f "$backup"
    fi

    ensure_collection
    crowdsec -t || die "CrowdSec configuration validation failed."
    systemctl enable crowdsec
    systemctl restart crowdsec
    systemctl is-active --quiet crowdsec || die "CrowdSec failed to start."
    log "Configured Nginx log targets:"
    printf '  - %s\n' "${logs[@]}"
}

install_timer(){
    install -d -o root -g root -m 0750 "$STACK_DIR"
    install -o root -g root -m 0750 "$SCRIPT_DIR/crowdsec.sh" "$INSTALLED_SCRIPT"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Refresh CrowdSec Nginx log discovery
After=network-online.target crowdsec.service nginx.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${INSTALLED_SCRIPT} --refresh
EOF
    cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=Periodically refresh CrowdSec Nginx log discovery
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true
[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload
    systemctl enable --now fedora-server-crowdsec-refresh.timer
}

install_crowdsec(){
    load_state
    local was_installed=false previous_managed="$MANAGED_INSTALL"
    if command -v crowdsec >/dev/null 2>&1 && command -v cscli >/dev/null 2>&1; then
        was_installed=true
        log "Existing CrowdSec installation detected."
    else
        command -v curl >/dev/null 2>&1 || die "curl is required."
        local bootstrap
        bootstrap=$(mktemp)
        curl -fsSL https://install.crowdsec.net -o "$bootstrap" ||
            { rm -f "$bootstrap"; die "Could not download official bootstrap."; }
        warn "The official bootstrap script will execute as root."
        read -r -p "Approve the downloaded bootstrap and install CrowdSec? [y/N] " answer
        if [[ ! $answer =~ ^[Yy]$ ]]; then
            rm -f "$bootstrap"; log "Installation cancelled."; return 0
        fi
        bash "$bootstrap" || { rm -f "$bootstrap"; die "Repository bootstrap failed."; }
        rm -f "$bootstrap"
        dnf install -y crowdsec || die "CrowdSec package installation failed."
    fi

    write_acquisition
    install_timer
    DECISION=installed
    if [[ $was_installed == true ]]; then MANAGED_INSTALL=$previous_managed
    else MANAGED_INSTALL=true; fi
    save_state
    log "Detection configured. No bouncer or automatic blocking enabled."
}

refresh(){
    command -v crowdsec >/dev/null 2>&1 || die "CrowdSec is not installed."
    write_acquisition
    install_timer
}

status(){
    load_state
    printf 'Decision: %s\nInstalled by this module: %s\n' "$DECISION" "$MANAGED_INSTALL"
    if command -v crowdsec >/dev/null 2>&1; then
        systemctl is-active crowdsec 2>/dev/null || true
        cscli collections list 2>/dev/null || true
        cscli metrics 2>/dev/null || true
    else
        echo "CrowdSec package: not installed"
    fi
    [[ ! -f $ACQUIS_FILE ]] || { echo "Acquisition file:"; cat "$ACQUIS_FILE"; }
    systemctl list-timers fedora-server-crowdsec-refresh.timer --no-pager 2>/dev/null || true
}

remove_integration(){
    if [[ -f $ACQUIS_FILE ]] && grep -Fqx "$MARKER" "$ACQUIS_FILE"; then rm -f "$ACQUIS_FILE"; fi
    systemctl disable --now fedora-server-crowdsec-refresh.timer 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$INSTALLED_SCRIPT"
    systemctl daemon-reload
    if command -v crowdsec >/dev/null 2>&1 && crowdsec -t; then systemctl restart crowdsec || true; fi
    rm -f "$STATE_FILE"
    log "Integration removed; CrowdSec package and unrelated configuration retained."
}

offer(){
    load_state
    case "$DECISION" in
        installed) log "CrowdSec already configured; skipping offer."; return 0 ;;
        declined) log "CrowdSec previously declined; skipping offer."; return 0 ;;
    esac
    cat <<'EOF'
Optional CrowdSec integration
CrowdSec analyzes host Nginx access logs in detection-only mode.
No bouncer, OPNsense rule, or automatic IP blocking is enabled.
EOF
    read -r -p "Install and configure CrowdSec now? [y/N] " answer
    if [[ $answer =~ ^[Yy]$ ]]; then install_crowdsec
    else DECISION=declined; save_state; log "Skipped; use the main installer menu to enable later."; fi
}

menu(){
    local choice
    echo
    echo "CrowdSec management"
    echo "  1) Install or configure"
    echo "  2) Refresh Nginx log discovery"
    echo "  3) Show status and metrics"
    echo "  4) Remove this repository integration"
    echo "  5) Return"
    read -r -p "Choose [1-5]: " choice
    case "$choice" in
        1) install_crowdsec ;;
        2) refresh ;;
        3) status ;;
        4) remove_integration ;;
        5) return 0 ;;
        *) die "Invalid selection." ;;
    esac
}

case "${1:-menu}" in
    --offer) offer ;;
    --install) install_crowdsec ;;
    --refresh) refresh ;;
    --status) status ;;
    --remove) remove_integration ;;
    menu) menu ;;
    *) die "Unknown CrowdSec action." ;;
esac
