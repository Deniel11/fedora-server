#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR=/etc/fedora-server-setup
STATE_FILE="${STATE_DIR}/crowdsec-state.env"
LOG_TARGETS="${STATE_DIR}/crowdsec-log-targets.txt"
ACQUIS_DIR=/etc/crowdsec/acquis.d
ACQUIS_FILE="${ACQUIS_DIR}/fedora-server-nginx.yaml"
STACK_DIR=/opt/fedora-server-setup
INSTALLED_SCRIPT="${STACK_DIR}/crowdsec.sh"
INSTALLED_PARSER="${STACK_DIR}/crowdsec-discovery.awk"
SERVICE_NAME=fedora-server-crowdsec-refresh
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"
RUNTIME_TIMER_FILE="/run/systemd/system/${SERVICE_NAME}.timer"
LOCK_FILE=/run/lock/fedora-server-crowdsec.lock
DECISION=unset
ACQUIS_SHA256=none
SERVICE_SHA256=none
TIMER_SHA256=none
RUNTIME_SHA256=none
PARSER_SHA256=none
LOG_TARGETS_SHA256=none
LEGACY_STATE=false
RESTART_PENDING=false
NGINX_GROUP_ADDED=false
TX_DIR=
TX_PATHS=()
TX_EXISTED=()
TX_LINK_TARGETS=()
TX_GROUP_ADDED=false
TX_TIMER_ENABLED=not-found
TX_TIMER_ACTIVE=unknown
TX_CROWDSEC_ACTIVE=unknown
TX_RESTORE_FAILED=false

log() { printf '[CrowdSec] %s\n' "$*"; }
warn() { printf '[CrowdSec] WARNING: %s\n' "$*" >&2; }
die() { printf '[CrowdSec] ERROR: %s\n' "$*" >&2; exit 1; }
file_hash() { sha256sum "$1" | awk '{print $1}'; }

require_root_fedora() {
    [[ $EUID -eq 0 ]] || die "Run with sudo or as root."
    [[ -r /etc/os-release ]] || die "Cannot identify the operating system."
    source /etc/os-release
    [[ ${ID:-} == fedora ]] || die "Fedora Server is required."
}

lock_module() {
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another CrowdSec operation is already running."
}

load_state() {
    DECISION=unset
    ACQUIS_SHA256=none
    SERVICE_SHA256=none
    TIMER_SHA256=none
    RUNTIME_SHA256=none
    PARSER_SHA256=none
    LOG_TARGETS_SHA256=none
    LEGACY_STATE=false
    RESTART_PENDING=false
    NGINX_GROUP_ADDED=false
    if [[ -e $STATE_DIR || -L $STATE_DIR ]]; then
        [[ -d $STATE_DIR && ! -L $STATE_DIR ]] || die "CrowdSec state directory must be a real directory."
        [[ $(stat -c '%U:%a' "$STATE_DIR") == root:700 || $(stat -c '%U:%a' "$STATE_DIR") == root:750 ]] || die "CrowdSec state directory must be root-owned with mode 0700 or 0750."
    fi
    [[ -e $STATE_FILE || -L $STATE_FILE ]] || return 0
    [[ -f $STATE_FILE && ! -L $STATE_FILE ]] || die "CrowdSec state must be a regular non-symlink file."
    [[ $(stat -c '%U:%a' "$STATE_FILE") == root:600 ]] || die "CrowdSec state must be root-owned with mode 0600."
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            CROWDSEC_DECISION) [[ $value =~ ^(installed|declined|removed_with_retained_files)$ ]] || die "Invalid CrowdSec state."; DECISION=$value ;;
            CROWDSEC_ACQUIS_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid acquisition ownership metadata."; ACQUIS_SHA256=$value ;;
            CROWDSEC_SERVICE_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid service ownership metadata."; SERVICE_SHA256=$value ;;
            CROWDSEC_TIMER_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid timer ownership metadata."; TIMER_SHA256=$value ;;
            CROWDSEC_RUNTIME_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid runtime ownership metadata."; RUNTIME_SHA256=$value ;;
            CROWDSEC_PARSER_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid parser ownership metadata."; PARSER_SHA256=$value ;;
            CROWDSEC_LOG_TARGETS_SHA256) [[ $value =~ ^([a-f0-9]{64}|none)$ ]] || die "Invalid log-target ownership metadata."; LOG_TARGETS_SHA256=$value ;;
            CROWDSEC_NGINX_GROUP_ADDED) [[ $value =~ ^(true|false)$ ]] || die "Invalid group metadata."; NGINX_GROUP_ADDED=$value ;;
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
    printf 'CROWDSEC_DECISION=%s\nCROWDSEC_ACQUIS_SHA256=%s\nCROWDSEC_SERVICE_SHA256=%s\nCROWDSEC_TIMER_SHA256=%s\nCROWDSEC_RUNTIME_SHA256=%s\nCROWDSEC_PARSER_SHA256=%s\nCROWDSEC_LOG_TARGETS_SHA256=%s\nCROWDSEC_LEGACY_MIGRATION=%s\nCROWDSEC_RESTART_PENDING=%s\nCROWDSEC_NGINX_GROUP_ADDED=%s\n' \
        "$DECISION" "$ACQUIS_SHA256" "$SERVICE_SHA256" "$TIMER_SHA256" "$RUNTIME_SHA256" "$PARSER_SHA256" "$LOG_TARGETS_SHA256" "$LEGACY_STATE" "$RESTART_PENDING" "$NGINX_GROUP_ADDED" > "$tmp"
    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

tx_begin() {
    TX_DIR=$(mktemp -d /var/tmp/fedora-server-crowdsec-tx.XXXXXX)
    TX_PATHS=()
    TX_EXISTED=()
    TX_LINK_TARGETS=()
    TX_GROUP_ADDED=false
    TX_TIMER_ENABLED=$(systemctl is-enabled "${SERVICE_NAME}.timer" 2>/dev/null || true)
    TX_TIMER_ACTIVE=$(systemctl is-active "${SERVICE_NAME}.timer" 2>/dev/null || true)
    TX_CROWDSEC_ACTIVE=$(systemctl is-active crowdsec 2>/dev/null || true)
    tx_snapshot "$ACQUIS_FILE"
    tx_snapshot "$LOG_TARGETS"
    tx_snapshot "$STATE_FILE"
    tx_snapshot "$INSTALLED_SCRIPT"
    tx_snapshot "$INSTALLED_PARSER"
    tx_snapshot "$SERVICE_FILE"
    tx_snapshot "$TIMER_FILE"
    tx_snapshot "$RUNTIME_TIMER_FILE"
}

restore_file_atomically() {
    local source="$1"
    local destination="$2"
    local directory
    local temporary
    directory=$(dirname "$destination")
    install -d "$directory" || return 1
    temporary=$(mktemp "${directory}/.crowdsec-restore.XXXXXX") || return 1
    if ! cp -p "$source" "$temporary" || ! mv -f "$temporary" "$destination"; then
        rm -f "$temporary"
        return 1
    fi
}

restore_runtime_pair() {
    local source_dir="$1"
    local restore_failed=false
    restore_file_atomically "${source_dir}/previous-script" "$INSTALLED_SCRIPT" || restore_failed=true
    restore_file_atomically "${source_dir}/previous-parser" "$INSTALLED_PARSER" || restore_failed=true
    [[ $restore_failed == false ]]
}

tx_snapshot() {
    local path="$1"
    local index
    if [[ -e $path || -L $path ]]; then
        if [[ -L $path ]]; then
            [[ $path == "$TIMER_FILE" || $path == "$RUNTIME_TIMER_FILE" ]] || die "Refusing to manage a non-regular path: $path"
            TX_PATHS+=("$path")
            TX_EXISTED+=(true)
            TX_LINK_TARGETS+=("$(readlink -- "$path")")
            return 0
        fi
        [[ -f $path ]] || die "Refusing to manage a non-regular path: $path"
        index=$((${#TX_PATHS[@]} + 1))
        mkdir -p "${TX_DIR}/${index}"
        cp -p "$path" "${TX_DIR}/${index}/file"
        TX_PATHS+=("$path")
        TX_EXISTED+=(true)
        TX_LINK_TARGETS+=("")
    else
        TX_PATHS+=("$path")
        TX_EXISTED+=(false)
        TX_LINK_TARGETS+=("")
    fi
}

tx_restore() {
    local i path index link_target
    TX_RESTORE_FAILED=false
    for ((i=${#TX_PATHS[@]}-1; i>=0; i--)); do
        path=${TX_PATHS[$i]}
        index=$((i+1))
        if [[ ${TX_EXISTED[$i]} == true ]]; then
            link_target=${TX_LINK_TARGETS[$i]}
            if [[ -n $link_target ]]; then
                rm -f -- "$path" && ln -s -- "$link_target" "$path" || TX_RESTORE_FAILED=true
            else
                restore_file_atomically "${TX_DIR}/${index}/file" "$path" || TX_RESTORE_FAILED=true
            fi
        else
            rm -f "$path" || TX_RESTORE_FAILED=true
        fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || TX_RESTORE_FAILED=true
    case "$TX_TIMER_ENABLED" in
        enabled) systemctl enable "${SERVICE_NAME}.timer" >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
        enabled-runtime) systemctl enable --runtime "${SERVICE_NAME}.timer" >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
        disabled) systemctl disable "${SERVICE_NAME}.timer" >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
        not-found|"") ;;
        masked) systemctl mask "${SERVICE_NAME}.timer" >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
        masked-runtime) systemctl mask --runtime "${SERVICE_NAME}.timer" >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
        linked|linked-runtime) ;;
    esac
    case "$TX_TIMER_ACTIVE" in
        active) systemctl start "${SERVICE_NAME}.timer" >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
        inactive) systemctl stop "${SERVICE_NAME}.timer" >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
        failed) systemctl stop "${SERVICE_NAME}.timer" >/dev/null 2>&1 || TX_RESTORE_FAILED=true; systemctl reset-failed "${SERVICE_NAME}.timer" >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
    esac
    if [[ $TX_GROUP_ADDED == true ]]; then
        gpasswd -d crowdsec nginx >/dev/null 2>&1 || TX_RESTORE_FAILED=true
    fi
    case "$TX_CROWDSEC_ACTIVE" in
        active) systemctl restart crowdsec >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
        inactive) systemctl stop crowdsec >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
        failed) systemctl stop crowdsec >/dev/null 2>&1 || TX_RESTORE_FAILED=true; systemctl reset-failed crowdsec >/dev/null 2>&1 || TX_RESTORE_FAILED=true ;;
    esac
    [[ $TX_RESTORE_FAILED == false ]]
}

tx_commit() {
    [[ -z $TX_DIR ]] || rm -rf "$TX_DIR"
    TX_DIR=
}

tx_abort() {
    if [[ -n $TX_DIR && -d $TX_DIR ]]; then
        if tx_restore; then
            rm -rf "$TX_DIR"
            TX_DIR=
        else
            warn "Rollback was incomplete. Recovery files were retained at: $TX_DIR"
            TX_DIR=
        fi
    fi
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

ensure_log_group_access() {
    id crowdsec >/dev/null 2>&1 || die "The CrowdSec service account does not exist."
    getent group nginx >/dev/null 2>&1 || die "The Nginx group does not exist; verify the Fedora Nginx package layout."
    if ! id -nG crowdsec | tr ' ' '\n' | grep -Fxq nginx; then
        usermod -aG nginx crowdsec || die "Could not add CrowdSec to the Nginx log-reading group."
        NGINX_GROUP_ADDED=true
        TX_GROUP_ADDED=true
        RESTART_PENDING=true
    fi
}

check_log_access() {
    local pattern file found=false
    while IFS= read -r pattern; do
        [[ -n $pattern ]] || continue
        while IFS= read -r file; do
            [[ -n $file ]] || continue
            found=true
            runuser -u crowdsec -- test -r "$file" || die "CrowdSec cannot read Nginx log file: $file. Check Nginx log ownership, logrotate create mode, group membership, and SELinux AVC records."
        done < <(compgen -G "$pattern" || true)
    done < "$LOG_TARGETS"
    [[ $found == true ]] || die "None of the discovered Nginx log patterns currently match a file."
}

validate_log_targets_ownership() {
    if [[ -e $LOG_TARGETS || -L $LOG_TARGETS ]]; then
        [[ -f $LOG_TARGETS && ! -L $LOG_TARGETS ]] || die "Refusing to manage a non-regular log-target state path."
        [[ $(stat -c '%U' "$LOG_TARGETS") == root ]] || die "Log-target state must be root-owned."
        local current_hash
        current_hash=$(file_hash "$LOG_TARGETS")
        if [[ $LOG_TARGETS_SHA256 != none ]]; then
            [[ $current_hash == "$LOG_TARGETS_SHA256" ]] || die "Refusing to overwrite log-target state changed outside this integration."
        elif [[ $LEGACY_STATE == true ]]; then
            LOG_TARGETS_SHA256=$current_hash
        else
            die "Refusing to overwrite log-target state not owned by this integration."
        fi
    fi
}

write_acquisition() {
    command -v crowdsec >/dev/null 2>&1 || die "CrowdSec is not installed."
    command -v cscli >/dev/null 2>&1 || die "cscli is unavailable."
    local discovered
    discovered=$(discover_logs) || die "Nginx log discovery failed."
    [[ -n $discovered ]] || die "No supported absolute Nginx access_log paths were found."
    validate_log_targets_ownership
    local -a logs=()
    mapfile -t logs <<< "$discovered"
    local existing_hash=none
    if [[ -e $ACQUIS_FILE || -L $ACQUIS_FILE ]]; then
        [[ -f $ACQUIS_FILE && ! -L $ACQUIS_FILE ]] || die "Refusing to replace a non-regular acquisition path."
        [[ $(stat -c '%U' "$ACQUIS_FILE") == root ]] || die "Acquisition file must be root-owned."
        existing_hash=$(file_hash "$ACQUIS_FILE")
        if [[ $ACQUIS_SHA256 != none ]]; then
            [[ $existing_hash == "$ACQUIS_SHA256" ]] || die "Refusing to overwrite an acquisition file changed outside this integration."
        elif [[ $LEGACY_STATE == true ]] && grep -Fqx '# Managed by fedora-server CrowdSec module.' "$ACQUIS_FILE"; then
            ACQUIS_SHA256=$existing_hash
        else
            die "Refusing to overwrite an acquisition file not owned by this integration."
        fi
    fi
    local foreign_file
    for foreign_file in /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.d/*.yaml; do
        [[ -f $foreign_file && $foreign_file != "$ACQUIS_FILE" ]] || continue
        if grep -Eq '^[[:space:]]*type:[[:space:]]*nginx([[:space:]]|$)' "$foreign_file"; then
            die "Another acquisition already declares the Nginx parser: $foreign_file."
        fi
    done
    install -d -o root -g root -m 0750 "$ACQUIS_DIR"
    local tmp path
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
        mv -f "$tmp" "$ACQUIS_FILE"
        chown root:root "$ACQUIS_FILE"
        chmod 0640 "$ACQUIS_FILE"
        ACQUIS_SHA256=$(file_hash "$ACQUIS_FILE")
        RESTART_PENDING=true
    fi
    printf '%s\n' "${logs[@]}" > "$LOG_TARGETS"
    chown root:root "$LOG_TARGETS"
    chmod 0600 "$LOG_TARGETS"
    LOG_TARGETS_SHA256=$(file_hash "$LOG_TARGETS")
    DECISION=installed
    save_state
}

install_runtime() {
    install -d -o root -g root -m 0750 "$STACK_DIR"
    if [[ -e $INSTALLED_SCRIPT || -L $INSTALLED_SCRIPT ]]; then
        [[ -f $INSTALLED_SCRIPT && ! -L $INSTALLED_SCRIPT ]] || die "Runtime script path is not a regular file."
        if [[ $RUNTIME_SHA256 != none ]]; then
            [[ $(file_hash "$INSTALLED_SCRIPT") == "$RUNTIME_SHA256" ]] || die "Refusing to replace a runtime script changed outside this integration."
        elif [[ $LEGACY_STATE == true ]] && grep -Fq 'MARKER="# Managed by fedora-server CrowdSec module."' "$INSTALLED_SCRIPT"; then
            RUNTIME_SHA256=$(file_hash "$INSTALLED_SCRIPT")
        else
            die "Refusing to replace an unowned runtime script."
        fi
    fi
    if [[ -e $INSTALLED_PARSER || -L $INSTALLED_PARSER ]]; then
        [[ -f $INSTALLED_PARSER && ! -L $INSTALLED_PARSER && $PARSER_SHA256 != none && $(file_hash "$INSTALLED_PARSER") == "$PARSER_SHA256" ]] || die "Refusing to replace an unowned discovery parser."
    fi
    install -o root -g root -m 0750 "$SCRIPT_DIR/crowdsec.sh" "$INSTALLED_SCRIPT"
    install -o root -g root -m 0644 "$SCRIPT_DIR/crowdsec-discovery.awk" "$INSTALLED_PARSER"
    RUNTIME_SHA256=$(file_hash "$INSTALLED_SCRIPT")
    PARSER_SHA256=$(file_hash "$INSTALLED_PARSER")
    save_state
}

install_units() {
    local service_tmp timer_tmp
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
        elif [[ $LEGACY_STATE == true ]] && grep -Fqx "ExecStart=${INSTALLED_SCRIPT} --refresh" "$SERVICE_FILE"; then
            SERVICE_SHA256=$(file_hash "$SERVICE_FILE")
        else
            die "Refusing to replace an unowned systemd service."
        fi
    fi
    if [[ -e $TIMER_FILE || -L $TIMER_FILE ]]; then
        [[ -f $TIMER_FILE && ! -L $TIMER_FILE ]] || die "Timer unit path is not a regular file."
        if [[ $TIMER_SHA256 != none ]]; then
            [[ $(file_hash "$TIMER_FILE") == "$TIMER_SHA256" ]] || die "Refusing to replace a timer unit changed outside this integration."
        elif [[ $LEGACY_STATE == true ]] && grep -Fqx 'Description=Periodically refresh CrowdSec Nginx log discovery' "$TIMER_FILE"; then
            TIMER_SHA256=$(file_hash "$TIMER_FILE")
        else
            die "Refusing to replace an unowned systemd timer."
        fi
    fi
    if ! cmp -s "$service_tmp" "$SERVICE_FILE" 2>/dev/null; then
        install -o root -g root -m 0644 "$service_tmp" "$SERVICE_FILE" || die "Could not install the CrowdSec refresh service."
    fi
    if ! cmp -s "$timer_tmp" "$TIMER_FILE" 2>/dev/null; then
        install -o root -g root -m 0644 "$timer_tmp" "$TIMER_FILE" || die "Could not install the CrowdSec refresh timer."
    fi
    rm -f "$service_tmp" "$timer_tmp"
    SERVICE_SHA256=$(file_hash "$SERVICE_FILE")
    TIMER_SHA256=$(file_hash "$TIMER_FILE")
    save_state
    systemctl daemon-reload || die "Could not reload systemd units."
    systemctl enable --now "${SERVICE_NAME}.timer" || die "Could not enable and start the CrowdSec refresh timer."
}

configure() {
    load_state
    trap 'tx_abort' EXIT
    tx_begin
    install -d -o root -g root -m 0700 "$STATE_DIR" || die "Could not create the state directory."
    ensure_log_group_access
    write_acquisition
    install_runtime
    ensure_collection
    crowdsec -t || die "CrowdSec configuration validation failed."
    check_log_access
    if [[ $RESTART_PENDING == true ]]; then
        systemctl restart crowdsec || die "CrowdSec could not restart with the updated configuration."
        RESTART_PENDING=false
        save_state
    fi
    systemctl enable crowdsec || die "Could not enable the CrowdSec service."
    systemctl is-active --quiet crowdsec || systemctl start crowdsec || die "Could not start CrowdSec."
    systemctl is-active --quiet crowdsec || die "CrowdSec is not active."
    install_units
    DECISION=installed
    LEGACY_STATE=false
    save_state
    tx_commit
    log "Detection-only configuration is active. No bouncer or blocking rule was installed."
    log "Configured Nginx access log patterns:"
    sed 's/^/  - /' "$LOG_TARGETS"
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
        warn "The displayed hash is informational and is not independently authenticated."
        read -r -p "Approve and execute this bootstrap with root privileges? [y/N] " answer
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

sync_runtime() {
    lock_module
    load_state
    [[ $DECISION == installed ]] || return 0
    [[ $RUNTIME_SHA256 != none && -f $INSTALLED_SCRIPT && ! -L $INSTALLED_SCRIPT ]] || die "CrowdSec runtime ownership metadata is incomplete."
    [[ $(file_hash "$INSTALLED_SCRIPT") == "$RUNTIME_SHA256" ]] || die "Refusing to update a runtime script changed outside this integration."
    [[ -f $INSTALLED_PARSER && ! -L $INSTALLED_PARSER && $PARSER_SHA256 != none && $(file_hash "$INSTALLED_PARSER") == "$PARSER_SHA256" ]] || die "Refusing to update a discovery parser changed outside this integration."
    local tmp_dir
    tmp_dir=$(mktemp -d "${STACK_DIR}/.crowdsec-sync.XXXXXX")
    cp -p "$INSTALLED_SCRIPT" "${tmp_dir}/previous-script"
    cp -p "$INSTALLED_PARSER" "${tmp_dir}/previous-parser"
    if ! install -o root -g root -m 0750 "$SCRIPT_DIR/crowdsec.sh" "${tmp_dir}/next-script" || ! install -o root -g root -m 0644 "$SCRIPT_DIR/crowdsec-discovery.awk" "${tmp_dir}/next-parser"; then
        rm -rf "$tmp_dir"
        die "Could not stage the updated CrowdSec runtime files."
    fi
    if ! mv -f "${tmp_dir}/next-script" "$INSTALLED_SCRIPT"; then
        rm -rf "$tmp_dir"
        die "Could not replace the CrowdSec runtime script."
    fi
    if ! mv -f "${tmp_dir}/next-parser" "$INSTALLED_PARSER"; then
        if restore_runtime_pair "$tmp_dir"; then
            rm -rf "$tmp_dir"
            die "Could not replace the CrowdSec discovery parser; previous runtime files were restored."
        fi
        die "Could not replace the CrowdSec discovery parser or restore the previous runtime pair. Recovery files were retained at: $tmp_dir"
    fi
    RUNTIME_SHA256=$(file_hash "$INSTALLED_SCRIPT")
    PARSER_SHA256=$(file_hash "$INSTALLED_PARSER")
    if ! save_state; then
        if restore_runtime_pair "$tmp_dir"; then
            rm -rf "$tmp_dir"
            die "Could not save CrowdSec runtime ownership metadata; previous runtime files were restored."
        fi
        die "Could not save CrowdSec runtime ownership metadata or restore the previous runtime pair. Recovery files were retained at: $tmp_dir"
    fi
    rm -rf "$tmp_dir"
    log "Managed CrowdSec runtime files updated."
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
    if [[ -f $LOG_TARGETS ]]; then
        echo 'Discovered log patterns:'
        sed 's/^/  - /' "$LOG_TARGETS"
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
    local retained=false
    if [[ -L $ACQUIS_FILE ]]; then
        retained=true
        warn "Acquisition path is a symbolic link and was retained."
    elif [[ -f $ACQUIS_FILE ]]; then
        if [[ $ACQUIS_SHA256 != none && $(file_hash "$ACQUIS_FILE") == "$ACQUIS_SHA256" ]] || { [[ $LEGACY_STATE == true ]] && grep -Fqx '# Managed by fedora-server CrowdSec module.' "$ACQUIS_FILE"; }; then
            rm -f "$ACQUIS_FILE"
        else
            retained=true
            warn "Acquisition file was changed or is not owned by this integration; it was retained."
        fi
    elif [[ -e $ACQUIS_FILE ]]; then
        retained=true
    fi
    if [[ -f $TIMER_FILE ]]; then
        if [[ $TIMER_SHA256 != none && $(file_hash "$TIMER_FILE") == "$TIMER_SHA256" ]] || { [[ $LEGACY_STATE == true ]] && grep -Fqx 'Description=Periodically refresh CrowdSec Nginx log discovery' "$TIMER_FILE"; }; then
            systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
            rm -f "$TIMER_FILE"
        else
            retained=true
            warn "Refresh timer was changed or is not owned by this integration; it was retained."
        fi
    elif [[ -e $TIMER_FILE || -L $TIMER_FILE ]]; then
        retained=true
    fi
    if [[ -f $SERVICE_FILE ]]; then
        if [[ $SERVICE_SHA256 != none && $(file_hash "$SERVICE_FILE") == "$SERVICE_SHA256" ]] || { [[ $LEGACY_STATE == true ]] && grep -Fqx "ExecStart=${INSTALLED_SCRIPT} --refresh" "$SERVICE_FILE"; }; then
            if [[ ! -e $TIMER_FILE ]]; then
                rm -f "$SERVICE_FILE"
            else
                retained=true
            fi
        else
            retained=true
            warn "Refresh service was changed or is not owned by this integration; it was retained."
        fi
    elif [[ -e $SERVICE_FILE || -L $SERVICE_FILE ]]; then
        retained=true
    fi
    if [[ -f $INSTALLED_SCRIPT ]]; then
        if [[ $RUNTIME_SHA256 != none && $(file_hash "$INSTALLED_SCRIPT") == "$RUNTIME_SHA256" ]] && [[ ! -e $SERVICE_FILE ]]; then
            rm -f "$INSTALLED_SCRIPT"
        else
            retained=true
            warn "Runtime script was retained because ownership could not be proven or its service still exists."
        fi
    fi
    if [[ -f $INSTALLED_PARSER ]]; then
        if [[ $PARSER_SHA256 != none && $(file_hash "$INSTALLED_PARSER") == "$PARSER_SHA256" ]] && [[ ! -e $SERVICE_FILE ]]; then
            rm -f "$INSTALLED_PARSER"
        else
            retained=true
            warn "Discovery parser was retained because ownership could not be proven or its service still exists."
        fi
    fi
    if [[ -L $LOG_TARGETS ]]; then
        retained=true
        warn "Log-target state path is a symbolic link and was retained."
    elif [[ -f $LOG_TARGETS ]]; then
        if [[ $LOG_TARGETS_SHA256 != none && $(file_hash "$LOG_TARGETS") == "$LOG_TARGETS_SHA256" ]]; then
            rm -f "$LOG_TARGETS"
        else
            retained=true
            warn "Log-target state was changed or is not owned by this integration; it was retained."
        fi
    elif [[ -e $LOG_TARGETS ]]; then
        retained=true
    fi
    if [[ $NGINX_GROUP_ADDED == true ]] && id -nG crowdsec | tr ' ' '\n' | grep -Fxq nginx; then
        if gpasswd -d crowdsec nginx >/dev/null 2>&1; then
            NGINX_GROUP_ADDED=false
        else
            retained=true
            warn "Could not remove the CrowdSec Nginx group membership."
        fi
    fi
    if [[ $retained == false ]]; then
        rm -f "$STATE_FILE"
    else
        DECISION=removed_with_retained_files
        save_state
    fi
    systemctl daemon-reload
    if [[ ! -e $ACQUIS_FILE ]] && command -v crowdsec >/dev/null 2>&1 && crowdsec -t; then
        systemctl restart crowdsec || warn "CrowdSec could not be restarted after acquisition removal."
    fi
    log "Repository integration cleanup finished. CrowdSec packages, databases, credentials, collections, and independent bouncers were retained."
}

offer() {
    load_state
    case "$DECISION" in
        installed) refresh; return 0 ;;
        declined) log "CrowdSec was previously declined. Use the main installer menu to enable it."; return 0 ;;
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
        4) lock_module; remove_integration ;;
        5) return 0 ;;
        *) die 'Invalid selection.' ;;
    esac
}

require_root_fedora
case "${1:-menu}" in
    --offer) offer ;;
    --install) lock_module; install_crowdsec ;;
    --refresh) refresh ;;
    --status) status ;;
    --remove) lock_module; remove_integration ;;
    --sync-runtime) sync_runtime ;;
    menu) menu ;;
    *) die "Unknown CrowdSec action: ${1:-}" ;;
esac
