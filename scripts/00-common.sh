#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/domains.conf"
STATE_DIR="/etc/fedora-server-setup"
TLS_DIR="${STATE_DIR}/tls"
NETWORK_STATE="${STATE_DIR}/network.env"
PROXMOX_STATE="${STATE_DIR}/proxmox.env"
INSTALL_STATE="${STATE_DIR}/install-state.env"
STACK_DIR="/opt/fedora-server-setup"
RUNTIME_APP_DIR="/opt/fedora-server-apps"
NGINX_RUNTIME_DIR="/etc/nginx/conf.d"

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
    source "$CONFIG_FILE"
}

validate_config() {
    local name value app_id extra_port
    local required=(PROXMOX_DOMAIN FEDORA_DOMAIN PROXMOX_PORT FEDORA_PORT)

    for name in "${required[@]}"; do
        value="${!name:-}"
        [[ -n "$value" ]] || die "Required configuration variable is missing: ${name}"
    done

    for name in PROXMOX_DOMAIN FEDORA_DOMAIN; do
        valid_hostname "${!name}" || die "Invalid hostname in config: ${name}=${!name}"
    done

    for name in PROXMOX_PORT FEDORA_PORT; do
        valid_port "${!name}" || die "Invalid TCP port in config: ${name}=${!name}"
    done

    local -A domain_owner=()
    local -A port_owner=()

    domain_owner["$PROXMOX_DOMAIN"]="proxmox"
    domain_owner["$FEDORA_DOMAIN"]="fedora"
    port_owner["$PROXMOX_PORT"]="proxmox"
    port_owner["$FEDORA_PORT"]="fedora"

    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue
        load_app_config "$app_id" || continue

        valid_hostname "$APP_DOMAIN" || die "Invalid application hostname: ${app_id}=${APP_DOMAIN}"
        valid_port "$APP_PORT" || die "Invalid application port: ${app_id}=${APP_PORT}"

        if [[ -n "${domain_owner[$APP_DOMAIN]:-}" && "${domain_owner[$APP_DOMAIN]}" != "$app_id" ]]; then
            die "Domain conflict: ${APP_DOMAIN} is assigned to both ${domain_owner[$APP_DOMAIN]} and ${app_id}."
        fi
        domain_owner["$APP_DOMAIN"]="$app_id"

        if [[ -n "${port_owner[$APP_PORT]:-}" && "${port_owner[$APP_PORT]}" != "$app_id" ]]; then
            die "Host port conflict: TCP ${APP_PORT} is assigned to both ${port_owner[$APP_PORT]} and ${app_id}."
        fi
        port_owner["$APP_PORT"]="$app_id"

        for extra_port in ${APP_EXTRA_PORTS:-}; do
            valid_port "$extra_port" || die "Invalid extra host port in ${app_id}: ${extra_port}"
            if [[ -n "${port_owner[$extra_port]:-}" && "${port_owner[$extra_port]}" != "$app_id" ]]; then
                die "Host port conflict: TCP ${extra_port} is assigned to both ${port_owner[$extra_port]} and ${app_id}."
            fi
            port_owner["$extra_port"]="$app_id"
        done
    done < <(app_ids)

    log "Central domain/port configuration is valid; no conflicts detected."
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

valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

valid_hostname() {
    local h="$1"
    [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

ensure_dirs() {
    install -d -m 0750 "$STATE_DIR" "$TLS_DIR" "$STACK_DIR" "$RUNTIME_APP_DIR"
}

write_install_state() {
    local last_stage="$1" resume_required="${2:-false}"
    ensure_dirs
    cat > "$INSTALL_STATE" <<EOF_STATE
INSTALL_IN_PROGRESS=true
LAST_STAGE=$(printf '%q' "$last_stage")
RESUME_REQUIRED=$(printf '%q' "$resume_required")
EOF_STATE
    chmod 600 "$INSTALL_STATE"
}

clear_install_state() {
    rm -f "$INSTALL_STATE"
}

run_stage() {
    local stage="$1" rc
    write_install_state "$stage" false
    log "Running ${stage}"
    set +e
    bash "${REPO_ROOT}/scripts/${stage}"
    rc=$?
    set -e
    if [[ "$rc" -eq 20 ]]; then
        warn "${stage} requested a reconnect/resume. Stop here and rerun the installer after reconnecting."
        exit 0
    fi
    [[ "$rc" -eq 0 ]] || exit "$rc"
}

app_dir() { printf '%s/apps/%s' "$REPO_ROOT" "$1"; }
app_runtime_dir() { printf '%s/%s' "$RUNTIME_APP_DIR" "$1"; }
app_compose_file() { printf '%s/compose.yml' "$(app_runtime_dir "$1")"; }

load_app_config() {
    local app_id="$1" conf
    conf="$(app_dir "$app_id")/app.conf"
    [[ -f "$conf" ]] || die "Missing application configuration: $conf"
    source "$conf"
    [[ "${APP_ID:-}" == "$app_id" ]] || die "Application config ${conf} has unexpected APP_ID=${APP_ID:-unset}"
    [[ "${APP_ENABLED:-true}" == "true" ]] || return 1
}

app_ids() {
    local dir app
    shopt -s nullglob
    for dir in "${REPO_ROOT}"/apps/*; do
        [[ -d "$dir" && -f "$dir/app.conf" && -f "$dir/install.sh" && -f "$dir/verify.sh" ]] || continue
        app="${dir##*/}"
        printf '%s\n' "$app"
    done
    shopt -u nullglob
}

app_name() {
    local app_id="$1"
    load_app_config "$app_id" || return 1
    printf '%s\n' "${APP_NAME}"
}

app_is_installed() {
    local app_id="$1"
    local runtime="$(app_runtime_dir "$app_id")"
    [[ -f "${runtime}/.installed" && -f "$(app_compose_file "$app_id")" ]]
}

app_is_running() {
    local app_id="$1"
    local container
    load_app_config "$app_id" || return 1
    container="${APP_CONTAINER:-$APP_ID}"
    docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true
}

app_prepare_runtime() {
    local app_id="$1" source_dir runtime
    source_dir="$(app_dir "$app_id")"
    runtime="$(app_runtime_dir "$app_id")"
    install -d -m 0750 "$runtime"
    cp "$source_dir/compose.yml" "$(app_compose_file "$app_id")"
    if [[ -f "$source_dir/.env.example" ]]; then
        cp "$source_dir/.env.example" "$runtime/.env.example"
    fi
}

app_config_signature() {
    printf '%s|%s|%s|%s|%s' "${APP_DOMAIN}" "${APP_PORT}" "${APP_EXTRA_PORTS:-}" "${APP_NGINX_ENABLED:-true}" "${APP_CERTIFICATE_ENABLED:-true}"
}

app_is_current() {
    local app_id="$1" runtime source_dir
    runtime="$(app_runtime_dir "$app_id")"
    source_dir="$(app_dir "$app_id")"
    [[ -f "${runtime}/.config" && -f "${runtime}/.compose.sha256" ]] || return 1
    [[ "$(cat "${runtime}/.config")" == "$(app_config_signature)" ]] || return 1
    [[ "$(cat "${runtime}/.compose.sha256")" == "$(sha256sum "${source_dir}/compose.yml" | awk '{print $1}')" ]]
}

app_write_state() {
    local app_id="$1" runtime source_dir
    runtime="$(app_runtime_dir "$app_id")"
    source_dir="$(app_dir "$app_id")"
    printf '%s' "$(app_config_signature)" > "${runtime}/.config"
    sha256sum "${source_dir}/compose.yml" | awk '{print $1}' > "${runtime}/.compose.sha256"
    chmod 600 "${runtime}/.config" "${runtime}/.compose.sha256"
    touch "${runtime}/.installed"
    chmod 600 "${runtime}/.installed"
}

app_compose_up() {
    local app_id="$1" runtime compose
    runtime="$(app_runtime_dir "$app_id")"
    compose="$(app_compose_file "$app_id")"
    if [[ "${RECONFIGURE:-false}" == "true" ]]; then
        ( cd "$runtime" && docker compose -f "$compose" up -d --force-recreate )
    else
        ( cd "$runtime" && docker compose -f "$compose" up -d )
    fi
}

app_compose_pull() {
    local app_id="$1" runtime compose
    runtime="$(app_runtime_dir "$app_id")"
    compose="$(app_compose_file "$app_id")"
    ( cd "$runtime" && docker compose -f "$compose" pull )
}

app_compose_ps() {
    local app_id="$1" runtime compose
    runtime="$(app_runtime_dir "$app_id")"
    compose="$(app_compose_file "$app_id")"
    ( cd "$runtime" && docker compose -f "$compose" ps )
}

install_app() {
    local app_id="$1"
    [[ -x "$(app_dir "$app_id")/install.sh" ]] || chmod +x "$(app_dir "$app_id")/install.sh"
    bash "$(app_dir "$app_id")/install.sh"
}

verify_app() {
    local app_id="$1"
    [[ -x "$(app_dir "$app_id")/verify.sh" ]] || chmod +x "$(app_dir "$app_id")/verify.sh"
    bash "$(app_dir "$app_id")/verify.sh"
}

app_nginx_install() {
    local app_id="$1" source_conf runtime_conf
    source_conf="$(app_dir "$app_id")/nginx.conf"
    runtime_conf="${NGINX_RUNTIME_DIR}/${app_id}.conf"
    [[ -f "$source_conf" ]] || return 0
    [[ "${APP_NGINX_ENABLED:-true}" == "true" ]] || return 0
    install -d -m 0755 "$NGINX_RUNTIME_DIR"
    sed \
        -e "s|__APP_DOMAIN__|${APP_DOMAIN}|g" \
        -e "s|__APP_PORT__|${APP_PORT}|g" \
        -e "s|__APP_TLS_NAME__|${APP_TLS_NAME}|g" \
        "$source_conf" > "$runtime_conf"
}

app_nginx_remove() {
    rm -f "${NGINX_RUNTIME_DIR}/$1.conf"
}

app_certificate_needed() {
    [[ "${APP_CERTIFICATE_ENABLED:-true}" == "true" ]]
}

app_cert_install() {
    local app_id="$1" domain cert key
    load_app_config "$app_id" || return 1
    domain="$APP_DOMAIN"
    cert="${TLS_DIR}/${APP_TLS_NAME}.crt"
    key="${TLS_DIR}/${APP_TLS_NAME}.key"
    [[ -s "$cert" && -s "$key" ]] || return 1
    return 0
}

sleep_after_disconnect_warning() {
    echo
    warn "The previous operation may disconnect your current SSH/Cockpit session."
    warn "After reconnecting, run: sudo ${STACK_DIR}/install.sh"
    echo
}
