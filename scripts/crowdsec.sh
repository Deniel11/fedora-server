#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR=/etc/fedora-server-setup
STATE_FILE="${STATE_DIR}/crowdsec-state.env"
ACQUIS_DIR=/etc/crowdsec/acquis.d
ACQUIS_FILE="${ACQUIS_DIR}/fedora-server-nginx.yaml"
STACK_DIR=/opt/fedora-server-setup
INSTALLED_SCRIPT="${STACK_DIR}/crowdsec.sh"
SERVICE_NAME=fedora-server-crowdsec-refresh
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"
LOCK_FILE=/run/lock/fedora-server-crowdsec.lock
DECISION=unset
ACQUIS_SHA256=none
SERVICE_SHA256=none
TIMER_SHA256=none
RUNTIME_SHA256=none
PARSER_SHA256=none
LEGACY_STATE=false
RESTART_PENDING=false

log() { printf '[CrowdSec] %s\n' "$*"; }
warn() { printf '[CrowdSec] WARNING: %s\n' "$*" >&2; }
die() { printf '[CrowdSec] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo or as root."
[[ -r /etc/os-release ]] || die "Cannot identify the operating system."
source /etc/os-release
[[ ${ID:-} == fedora ]] || die "Fedora Server is required."

load_state() {
    DECISION=unset
    ACQUIS_SHA256=none
    SERVICE_SHA256=none
    TIMER_SHA256=none
    RUNTIME_SHA256=none
    PARSER_SHA256=none
    LEGACY_STATE=false
    RESTART_PENDING=false
    if [[ -e $STATE_DIR || -L $STATE_DIR ]]; then
        [[ -d $STATE_DIR && ! -L $STATE_DIR ]] || die "CrowdSec state directory must be a real directory."
        [[ $(stat -c '%U:%a' "$STATE_DIR") == root:700 ]] || die "CrowdSec state directory must be root-owned with mode 0700."
    fi
    [[ -e $STATE_FILE || -L $STATE_FILE ]] || return 0
    [[ -f $STATE_FILE && ! -L $STATE_FILE ]] || die "CrowdSec state must be a regular non-symlink file."
    [[ $(stat -c '%U:%a' "$STATE_FILE") == root:600 ]] || die "CrowdSec state must be root-owned with mode 0600."
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            CROWDSEC_DECISION) [[ $value =~ ^(installed|declined)$ ]] || die "Invalid CrowdSec state."; DECISION=$value ;;
            CROWDSEC_ACQUIS_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid acquisition ownership metadata."; ACQUIS_SHA256=$value ;;
            CROWDSEC_SERVICE_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid service ownership metadata."; SERVICE_SHA256=$value ;;
            CROWDSEC_TIMER_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid timer ownership metadata."; TIMER_SHA256=$value ;;
            CROWDSEC_RUNTIME_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid runtime ownership metadata."; RUNTIME_SHA256=$value ;;
            CROWDSEC_PARSER_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid parser ownership metadata."; PARSER_SHA256=$value ;;
            CROWDSEC_LEGACY_MIGRATION) [[ $value =~ ^(true|false)$ ]] || die "Invalid migration metadata."; LEGACY_STATE=$value ;;
            CROWDSEC_RESTART_PENDING) [[ $value =~ ^(true|false)$ ]] || die "Invalid restart metadata."; RESTART_PENDING=$value ;;
            CROWDSEC_MANAGED_INSTALL) [[ $value =~ ^(true|false)$ ]] || die "Invalid legacy installation metadata."; LEGACY_STATE=true ;;
            *) die "Unexpected key in CrowdSec state: $key" ;;
        esac
    done < "$STATE_FILE"
}

save_state() {
    install -d -o root -g root -m 0700 "$STATE_DIR"
    local tmp
    tmp=$(mktemp "${STATE_DIR}/.crowdsec-state.XXXXXX")
    printf 'CROWDSEC_DECISION=%s\nCROWDSEC_ACQUIS_SHA256=%s\nCROWDSEC_SERVICE_SHA256=%s\nCROWDSEC_TIMER_SHA256=%s\nCROWDSEC_RUNTIME_SHA256=%s\nCROWDSEC_PARSER_SHA256=%s\nCROWDSEC_LEGACY_MIGRATION=%s\nCROWDSEC_RESTART_PENDING=%s\n' \
        "$DECISION" "$ACQUIS_SHA256" "$SERVICE_SHA256" "$TIMER_SHA256" "$RUNTIME_SHA256" "$PARSER_SHA256" "$LEGACY_STATE" "$RESTART_PENDING" > "$tmp"
    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

file_hash() {
    sha256sum "$1" | awk '{print $1}'
}

lock_module() {
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another CrowdSec operation is already running."
}

discover_logs() {
    command -v nginx >/dev/null 2>&1 || { warn "Nginx is not installed."; return 1; }
    local dump
    dump=$(nginx -T 2>&1) || { warn "nginx -T failed; fix the Nginx configuration."; return 1; }
    printf '%s\n' "$dump" | awk -f "${SCRIPT_DIR}/crowdsec-discovery.awk" | sort -u
}

ensure_collection() {
    if ! cscli collections list 2>/dev/null | grep -Fq 'crowdsecurity/nginx'; then
        cscli collections install crowdsecurity/nginx || die "Could not install crowdsecurity/nginx."
        RESTART_PENDING=true
    fi
}

write_acquisition() {
    command -v crowdsec >/dev/null 2>&1 || die "CrowdSec is not installed."
    command -v cscli >/dev/null 2>&1 || die "cscli is unavailable."
    local discovered
    discovered=$(discover_logs) || die "Nginx log discovery failed."
    [[ -n $discovered ]] || die "No supported absolute Nginx access_log paths were found."
    local -a logs=()
    mapfile -t logs <<< "$discovered"
    local existing_hash=none
    if [[ -e $ACQUIS_FILE || -L $ACQUIS_FILE ]]; then
        [[ -f $ACQUIS_FILE && ! -L $ACQUIS_FILE ]] || die "Refusing to replace a non-regular acquisition path."
        [[ $(stat -c '%U' "$ACQUIS_FILE") == root ]] || die "Acquisition file must be root-owned."
        existing_hash=$(file_hash "$ACQUIS_FILE")
        if [[ $ACQUIS_SHA256 != none ]]; then
            [[ $existing_hash == "$ACQUIS_SHA256" ]] || die "Refusing to overwrite an acquisition file changed outside this integration: $ACQUIS_FILE"
        elif [[ $LEGACY_STATE == true ]] && grep -Fqx '# Managed by fedora-server CrowdSec module.' "$ACQUIS_FILE"; then
            ACQUIS_SHA256=$existing_hash
        else
            die "Refusing to overwrite an acquisition file not owned by this integration: $ACQUIS_FILE"
        fi
    fi
    local foreign_file
    for foreign_file in /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.d/*.yaml; do
        [[ -f $foreign_file && $foreign_file != "$ACQUIS_FILE" ]] || continue
        if grep -Eq '^[[:space:]]*type:[[:space:]]*nginx([[:space:]]|$)' "$foreign_file"; then
            die "Another acquisition already declares the Nginx parser: $foreign_file. Review it before enabling this integration."
        fi
    done
    install -d -o root -g root -m 0750 "$ACQUIS_DIR"
    local tmp backup="" path
    tmp=$(mktemp "${ACQUIS_DIR}/.fedora-server-nginx.XXXXXX")
    {
        printf 'source: file\nfilenames:\n'
        for path in "${logs[@]}"; do
            path=${path//\'/\'\'}
            printf "  - '%s'\n" "$path"
        done
        printf 'discovery_poll_enable: true\ndiscovery_poll_interval: 30s\nlabels:\n  type: nginx\n'
    } > "$tmp"
    chmod 0640 "$tmp"
    if [[ -f $ACQUIS_FILE ]] && cmp -s "$tmp" "$ACQUIS_FILE"; then
        rm -f "$tmp"
        ACQUIS_SHA256=$existing_hash
    else
        if [[ -f $ACQUIS_FILE ]]; then
            backup=$(mktemp "${ACQUIS_DIR}/.fedora-server-nginx-backup.XXXXXX")
            cp -p "$ACQUIS_FILE" "$backup"
        fi
        mv -f "$tmp" "$ACQUIS_FILE"
        chown root:root "$ACQUIS_FILE"
        chmod 0640 "$ACQUIS_FILE"
        if ! crowdsec -t >/dev/null 2>&1; then
            if [[ -n $backup ]]; then
                mv -f "$backup" "$ACQUIS_FILE"
            else
                rm -f "$ACQUIS_FILE"
            fi
            die "Generated acquisition configuration failed validation; the previous file was restored."
        fi
        [[ -z $backup ]] || rm -f "$backup"
        ACQUIS_SHA256=$(file_hash "$ACQUIS_FILE")
        RESTART_PENDING=true
    fi
    printf '%s\n' "${logs[@]}" > "${STATE_DIR}/crowdsec-log-targets.txt"
    chown root:root "${STATE_DIR}/crowdsec-log-targets.txt"
    chmod 0600 "${STATE_DIR}/crowdsec-log-targets.txt"
    DECISION=installed
    save_state
    check_log_access
}

check_log_access() {
    local pattern file found=false
    while IFS= read -r pattern; do
        [[ -n $pattern ]] || continue
        while IFS= read -r file; do
            [[ -n $file ]] || continue
            found=true
            if id crowdsec >/dev/null 2>&1; then
                runuser -u crowdsec -- test -r "$file" || die "CrowdSec cannot read Nginx log file: $file. Check group access and SELinux AVC records."
            else
                [[ -r $file ]] || die "Nginx log file is not readable: $file"
            fi
        done < <(compgen -G "$pattern" || true)
    done < "${STATE_DIR}/crowdsec-log-targets.txt"
    [[ $found == true ]] || die "None of the discovered Nginx log patterns currently match a file."
}

install_timer() {
    install -d -o root -g root -m 0750 "$STACK_DIR"
    if [[ -e $INSTALLED_SCRIPT || -L $INSTALLED_SCRIPT ]]; then
        [[ -f $INSTALLED_SCRIPT && ! -L $INSTALLED_SCRIPT ]] || die "Runtime script path is not a regular file."
        if [[ $RUNTIME_SHA256 != none ]]; then
            [[ $(file_hash "$INSTALLED_SCRIPT") == "$RUNTIME_SHA256" ]] || die "Refusing to replace a runtime script changed outside this integration."
        elif [[ $LEGACY_STATE == true ]] && grep -Fq 'MARKER="# Managed by fedora-server CrowdSec module."' "$INSTALLED_SCRIPT"; then
            RUNTIME_SHA256=$(file_hash "$INSTALLED_SCRIPT")
        else
            die "Refusing to replace an unowned runtime script: $INSTALLED_SCRIPT"
        fi
    fi
    if [[ -e ${STACK_DIR}/crowdsec-discovery.awk || -L ${STACK_DIR}/crowdsec-discovery.awk ]]; then
        [[ -f ${STACK_DIR}/crowdsec-discovery.awk && ! -L ${STACK_DIR}/crowdsec-discovery.awk && $PARSER_SHA256 != none && $(file_hash "${STACK_DIR}/crowdsec-discovery.awk") == "$PARSER_SHA256" ]] || die "Refusing to replace an unowned discovery parser."
    fi
    if [[ ! -f $INSTALLED_SCRIPT ]] || ! cmp -s "$SCRIPT_DIR/crowdsec.sh" "$INSTALLED_SCRIPT"; then
        install -o root -g root -m 0750 "$SCRIPT_DIR/crowdsec.sh" "$INSTALLED_SCRIPT"
    fi
    if [[ ! -f ${STACK_DIR}/crowdsec-discovery.awk ]] || ! cmp -s "$SCRIPT_DIR/crowdsec-discovery.awk" "${STACK_DIR}/crowdsec-discovery.awk"; then
        install -o root -g root -m 0644 "$SCRIPT_DIR/crowdsec-discovery.awk" "${STACK_DIR}/crowdsec-discovery.awk"
    fi
    RUNTIME_SHA256=$(file_hash "$INSTALLED_SCRIPT")
    PARSER_SHA256=$(file_hash "${STACK_DIR}/crowdsec-discovery.awk")
    save_state
    local service_tmp timer_tmp changed=false
    service_tmp=$(mktemp)
    timer_tmp=$(mktemp)
    cat > "$service_tmp" <<EOF_SERVICE
[Unit]
Description=Refresh CrowdSec Nginx log discovery
After=network-online.target crowdsec.service nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALLED_SCRIPT} --refresh
EOF_SERVICE
    cat > "$timer_tmp" <<'EOF_TIMER'
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
    chmod 0644 "$service_tmp" "$timer_tmp"
    if [[ -e $SERVICE_FILE || -L $SERVICE_FILE ]]; then
        [[ -f $SERVICE_FILE && ! -L $SERVICE_FILE ]] || die "Service unit path is not a regular file."
        if [[ $SERVICE_SHA256 != none ]]; then
            [[ $(file_hash "$SERVICE_FILE") == "$SERVICE_SHA256" ]] || die "Refusing to replace a service unit changed outside this integration."
        elif [[ $LEGACY_STATE == true ]] && grep -Fqx "ExecStart=${INSTALLED_SCRIPT} --refresh" "$SERVICE_FILE" && grep -Fqx 'Description=Refresh CrowdSec Nginx log discovery' "$SERVICE_FILE"; then
            SERVICE_SHA256=$(file_hash "$SERVICE_FILE")
        else
            die "Refusing to replace an unowned systemd service: $SERVICE_FILE"
        fi
    fi
    if [[ -e $TIMER_FILE || -L $TIMER_FILE ]]; then
        [[ -f $TIMER_FILE && ! -L $TIMER_FILE ]] || die "Timer unit path is not a regular file."
        if [[ $TIMER_SHA256 != none ]]; then
            [[ $(file_hash "$TIMER_FILE") == "$TIMER_SHA256" ]] || die "Refusing to replace a timer unit changed outside this integration."
        elif [[ $LEGACY_STATE == true ]] && grep -Fqx 'Description=Periodically refresh CrowdSec Nginx log discovery' "$TIMER_FILE" && grep -Fqx 'OnUnitActiveSec=5min' "$TIMER_FILE"; then
            TIMER_SHA256=$(file_hash "$TIMER_FILE")
        else
            die "Refusing to replace an unowned systemd timer: $TIMER_FILE"
        fi
    fi
    if [[ ! -f $SERVICE_FILE ]] || ! cmp -s "$service_tmp" "$SERVICE_FILE"; then
        mv -f "$service_tmp" "$SERVICE_FILE"
        changed=true
    fi
    if [[ ! -f $TIMER_FILE ]] || ! cmp -s "$timer_tmp" "$TIMER_FILE"; then
        mv -f "$timer_tmp" "$TIMER_FILE"
        changed=true
    fi
    rm -f "$service_tmp" "$timer_tmp"
    chown root:root "$SERVICE_FILE" "$TIMER_FILE"
    chmod 0644 "$SERVICE_FILE" "$TIMER_FILE"
    SERVICE_SHA256=$(file_hash "$SERVICE_FILE")
    TIMER_SHA256=$(file_hash "$TIMER_FILE")
    DECISION=installed
    save_state
    if [[ $changed == true ]]; then
        systemctl daemon-reload
    fi
    systemctl is-enabled --quiet "${SERVICE_NAME}.timer" || systemctl enable "${SERVICE_NAME}.timer"
    systemctl is-active --quiet "${SERVICE_NAME}.timer" || systemctl start "${SERVICE_NAME}.timer"
}

configure() {
    load_state
    install -d -o root -g root -m 0700 "$STATE_DIR"
    write_acquisition
    DECISION=installed
    save_state
    ensure_collection
    save_state
    crowdsec -t || die "CrowdSec configuration validation failed."
    if [[ $RESTART_PENDING == true ]]; then
        systemctl restart crowdsec
        RESTART_PENDING=false
        save_state
    fi
    systemctl enable crowdsec
    systemctl is-active --quiet crowdsec || systemctl start crowdsec
    systemctl is-active --quiet crowdsec || die "CrowdSec is not active."
    install_timer
    DECISION=installed
    LEGACY_STATE=false
    save_state
    log "Detection-only configuration is active. No bouncer or blocking rule was installed."
    log "Configured Nginx access log patterns:"
    sed 's/^/  - /' "${STATE_DIR}/crowdsec-log-targets.txt"
}

install_crowdsec() {
    if command -v crowdsec >/dev/null 2>&1 && command -v cscli >/dev/null 2>&1; then
        log "Existing CrowdSec installation detected."
    else
        command -v curl >/dev/null 2>&1 || die "curl is required."
        command -v dnf >/dev/null 2>&1 || die "dnf is required."
        local bootstrap checksum answer
        bootstrap=$(mktemp)
        trap 'rm -f "${bootstrap:-}"' EXIT
        curl --proto '=https' --tlsv1.2 -fL --retry 2 https://install.crowdsec.net -o "$bootstrap" || die "Could not download the official CrowdSec bootstrap script."
        checksum=$(sha256sum "$bootstrap" | awk '{print $1}')
        printf 'Downloaded bootstrap: https://install.crowdsec.net\nSHA-256: %s\n' "$checksum"
        warn "The downloaded bootstrap will execute with root privileges. The displayed hash is informational and is not independently authenticated."
        read -r -p "Approve and execute this bootstrap, then install CrowdSec? [y/N] " answer
        if [[ ! $answer =~ ^[Yy]$ ]]; then
            rm -f "$bootstrap"
            trap - EXIT
            DECISION=declined
            save_state
            log "Installation declined."
            return 0
        fi
        bash "$bootstrap" || die "CrowdSec repository bootstrap failed."
        rm -f "$bootstrap"
        trap - EXIT
        dnf install -y crowdsec || die "CrowdSec package installation failed."
    fi
    configure
}

refresh() {
    lock_module
    load_state
    [[ $DECISION == installed ]] || die "CrowdSec integration is not marked as installed."
    configure
}

status() {
    load_state
    printf 'Integration decision: %s\n' "$DECISION"
    if ! command -v crowdsec >/dev/null 2>&1; then
        echo 'CrowdSec package: not installed'
        return 0
    fi
    printf 'CrowdSec service: '
    systemctl is-active crowdsec 2>/dev/null || true
    printf 'Refresh timer: '
    systemctl is-active "${SERVICE_NAME}.timer" 2>/dev/null || true
    crowdsec -t
    cscli collections list 2>/dev/null || true
    cscli metrics 2>/dev/null || true
    if [[ -f "$STATE_DIR/crowdsec-log-targets.txt" ]]; then
        echo 'Discovered log patterns:'
        sed 's/^/  - /' "$STATE_DIR/crowdsec-log-targets.txt"
    fi
    if [[ -f $ACQUIS_FILE ]]; then
        echo 'Acquisition configuration:'
        cat "$ACQUIS_FILE"
    fi
    if command -v ausearch >/dev/null 2>&1; then
        echo 'Recent SELinux denials affecting CrowdSec or Nginx:'
        ausearch -m AVC -ts recent 2>/dev/null | grep -Ei 'crowdsec|nginx' | tail -n 10 || true
    fi
}

remove_integration() {
    load_state
    local acquisition_removed=false units_changed=false timer_managed=true service_managed=true
    if [[ -f $ACQUIS_FILE ]] && {
        [[ $ACQUIS_SHA256 != none && $(file_hash "$ACQUIS_FILE") == "$ACQUIS_SHA256" ]] || { [[ $LEGACY_STATE == true ]] && grep -Fqx '# Managed by fedora-server CrowdSec module.' "$ACQUIS_FILE"; }
    }; then
        rm -f "$ACQUIS_FILE"
        acquisition_removed=true
    elif [[ -e $ACQUIS_FILE ]]; then
        warn "Acquisition file was changed or is not owned by this integration; it was retained."
    fi
    if [[ -f $TIMER_FILE ]] && {
        [[ $TIMER_SHA256 != none && $(file_hash "$TIMER_FILE") == "$TIMER_SHA256" ]] || { [[ $LEGACY_STATE == true ]] && grep -Fqx 'Description=Periodically refresh CrowdSec Nginx log discovery' "$TIMER_FILE"; }
    }; then
        systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
        systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
        rm -f "$TIMER_FILE"
        units_changed=true
    elif [[ -e $TIMER_FILE ]]; then
        timer_managed=false
        warn "Refresh timer was changed or is not owned by this integration; it was retained."
    fi
    if [[ -f $SERVICE_FILE && $timer_managed == true ]] && {
        [[ $SERVICE_SHA256 != none && $(file_hash "$SERVICE_FILE") == "$SERVICE_SHA256" ]] || { [[ $LEGACY_STATE == true ]] && grep -Fqx "ExecStart=${INSTALLED_SCRIPT} --refresh" "$SERVICE_FILE" && grep -Fqx 'Description=Refresh CrowdSec Nginx log discovery' "$SERVICE_FILE"; }
    }; then
        rm -f "$SERVICE_FILE"
        units_changed=true
    elif [[ -e $SERVICE_FILE ]]; then
        service_managed=false
        warn "Refresh service was changed or is not owned by this integration; it was retained."
    elif [[ $timer_managed == false ]]; then
        service_managed=false
    fi
    if [[ -f $INSTALLED_SCRIPT && $service_managed == true ]] && {
        [[ $RUNTIME_SHA256 != none && $(file_hash "$INSTALLED_SCRIPT") == "$RUNTIME_SHA256" ]] || { [[ $LEGACY_STATE == true ]] && grep -Fq 'MARKER="# Managed by fedora-server CrowdSec module."' "$INSTALLED_SCRIPT"; }
    }; then
        rm -f "$INSTALLED_SCRIPT"
    elif [[ -e $INSTALLED_SCRIPT ]]; then
        warn "Runtime script was changed or is not owned by this integration; it was retained."
        service_managed=false
    fi
    if [[ -f ${STACK_DIR}/crowdsec-discovery.awk && $service_managed == true ]] && [[ $PARSER_SHA256 != none && $(file_hash "${STACK_DIR}/crowdsec-discovery.awk") == "$PARSER_SHA256" ]]; then
        rm -f "${STACK_DIR}/crowdsec-discovery.awk"
    elif [[ -e ${STACK_DIR}/crowdsec-discovery.awk ]]; then
        warn "Discovery parser was changed or is not owned by this integration; it was retained."
    fi
    rm -f "$STATE_DIR/crowdsec-log-targets.txt" "$STATE_FILE"
    if [[ $units_changed == true ]]; then
        systemctl daemon-reload
    fi
    if [[ $acquisition_removed == true ]] && command -v crowdsec >/dev/null 2>&1 && crowdsec -t; then
        systemctl restart crowdsec || true
    fi
    log "Repository integration removed. CrowdSec packages, database, credentials, collections, bouncers, and unrelated configuration were retained."
}

offer() {
    load_state
    case "$DECISION" in
        installed)
            refresh
            return 0
            ;;
        declined)
            log "CrowdSec was previously declined. Use the main installer menu to enable it."
            return 0
            ;;
    esac
    cat <<'EOF_OFFER'
Optional CrowdSec integration
CrowdSec analyzes access logs from the host-managed Nginx reverse proxy in detection-only mode.
This integration does not install a bouncer, change OPNsense, or enable automatic blocking.
EOF_OFFER
    local answer
    read -r -p "Install and configure CrowdSec now? [y/N] " answer
    if [[ $answer =~ ^[Yy]$ ]]; then
        lock_module
        install_crowdsec
    else
        DECISION=declined
        save_state
        log "Skipped. You can enable CrowdSec later from the main installer menu."
    fi
}

menu() {
    local choice
    echo
    echo 'CrowdSec management'
    echo '  1) Install or configure'
    echo '  2) Refresh Nginx log discovery'
    echo '  3) Show status and metrics'
    echo '  4) Remove this repository integration'
    echo '  5) Return'
    read -r -p 'Choose [1-5]: ' choice
    case "$choice" in
        1) lock_module; install_crowdsec ;;
        2) refresh ;;
        3) status ;;
        4) remove_integration ;;
        5) return 0 ;;
        *) die 'Invalid selection.' ;;
    esac
}

case "${1:-menu}" in
    --offer) offer ;;
    --install) lock_module; install_crowdsec ;;
    --refresh) refresh ;;
    --status) status ;;
    --remove) lock_module; remove_integration ;;
    menu) menu ;;
    *) die "Unknown CrowdSec action: ${1:-}" ;;
esac
