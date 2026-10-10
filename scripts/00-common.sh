#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/domains.conf"
STATE_DIR="/etc/fedora-server-setup"
TLS_DIR="${STATE_DIR}/tls"
NETWORK_STATE="${STATE_DIR}/network.env"
PROXMOX_STATE="${STATE_DIR}/proxmox.env"
DOMAIN_STATE="${STATE_DIR}/domain.env"
GODADDY_CREDENTIALS="${STATE_DIR}/godaddy.ini"
INSTALL_STATE="${STATE_DIR}/install-state.env"
STACK_DIR="/opt/fedora-server-setup"
RUNTIME_APP_DIR="/opt/fedora-server-apps"
NGINX_RUNTIME_DIR="/etc/nginx/conf.d"
ACME_WEBROOT="/var/www/fedora-server-acme"

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

load_domain_state() {
    if [[ -f "$DOMAIN_STATE" ]]; then
        source "$DOMAIN_STATE"
    fi

    DOMAIN_MODE="${DOMAIN_MODE:-local}"
    BASE_DOMAIN="${BASE_DOMAIN:-}"
    APP_SUBDOMAIN="${APP_SUBDOMAIN:-home}"

    if [[ "$DOMAIN_MODE" == "public" ]]; then
        [[ -n "$BASE_DOMAIN" ]] || die "DOMAIN_MODE=public requires BASE_DOMAIN in ${DOMAIN_STATE}"

        local prefix="${APP_SUBDOMAIN%.}"
        prefix="${prefix#.}"

        if [[ -n "$prefix" ]]; then
            FEDORA_DOMAIN="fedora-server.${prefix}.${BASE_DOMAIN}"
            PROXMOX_DOMAIN="proxmox.${prefix}.${BASE_DOMAIN}"
            PORTAINER_DOMAIN="portainer.${prefix}.${BASE_DOMAIN}"
            VAULTWARDEN_DOMAIN="vault.${prefix}.${BASE_DOMAIN}"
            JOPLIN_DOMAIN="joplin.${prefix}.${BASE_DOMAIN}"
            FORGEJO_DOMAIN="forgejo.${prefix}.${BASE_DOMAIN}"
        else
            FEDORA_DOMAIN="fedora-server.${BASE_DOMAIN}"
            PROXMOX_DOMAIN="proxmox.${BASE_DOMAIN}"
            PORTAINER_DOMAIN="portainer.${BASE_DOMAIN}"
            VAULTWARDEN_DOMAIN="vault.${BASE_DOMAIN}"
            JOPLIN_DOMAIN="joplin.${BASE_DOMAIN}"
            FORGEJO_DOMAIN="forgejo.${BASE_DOMAIN}"
        fi
    fi
}

save_domain_state() {
    install -d -m 0750 "$STATE_DIR"

    cat > "$DOMAIN_STATE" <<EOF_DOMAIN
DOMAIN_MODE=$(printf '%q' "${DOMAIN_MODE}")
BASE_DOMAIN=$(printf '%q' "${BASE_DOMAIN:-}")
APP_SUBDOMAIN=$(printf '%q' "${APP_SUBDOMAIN:-home}")
ACME_EMAIL=$(printf '%q' "${ACME_EMAIL:-}")
EOF_DOMAIN

    chmod 600 "$DOMAIN_STATE"
}

save_godaddy_credentials() {
    local pat="$1"

    install -d -m 0750 "$STATE_DIR"

    cat > "$GODADDY_CREDENTIALS" <<EOF_GODADDY
GODADDY_PAT=$(printf '%q' "$pat")
EOF_GODADDY

    chown root:root "$GODADDY_CREDENTIALS"
    chmod 600 "$GODADDY_CREDENTIALS"
}

godaddy_credentials_valid() {
    [[ -s "$GODADDY_CREDENTIALS" ]] || return 1
    grep -Eq '^GODADDY_PAT[[:space:]]*=' "$GODADDY_CREDENTIALS" || return 1
}

ensure_godaddy_credentials() {
    [[ "${DOMAIN_MODE:-local}" == "public" ]] || return 0
    godaddy_credentials_valid && return 0

    echo
    echo "GoDaddy DNS-01 credentials are required for public HTTPS certificates."
    echo "Create a GoDaddy Personal Access Token (PAT) with the domains.dns:update scope."
    echo

    local pat

    read -r -s -p "GoDaddy PAT: " pat
    echo

    [[ -n "$pat" ]] || die "A GoDaddy PAT is required for public mode."

    save_godaddy_credentials "$pat"
    unset pat
}

validate_config() {
    local name value app_id extra_port
    DOMAIN_MODE="${DOMAIN_MODE:-local}"
    BASE_DOMAIN="${BASE_DOMAIN:-}"
    APP_SUBDOMAIN="${APP_SUBDOMAIN:-home}"
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

    if [[ "$DOMAIN_MODE" == "public" ]]; then
        valid_hostname "$BASE_DOMAIN" || die "Invalid base domain: ${BASE_DOMAIN}"
        valid_domain_prefix "$APP_SUBDOMAIN" || die "Invalid application subdomain prefix: ${APP_SUBDOMAIN}"
    fi

    local -A domain_owner=()
    local -A port_owner=()

    domain_owner["$PROXMOX_DOMAIN"]=proxmox
    domain_owner["$FEDORA_DOMAIN"]=fedora

    port_owner["$PROXMOX_PORT"]=proxmox
    port_owner["$FEDORA_PORT"]=fedora

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
    local ip="$1"
    local octet

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

valid_domain_prefix() {
    local p="$1"
    [[ -z "$p" || "$p" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$ ]]
}

ensure_dirs() {
    install -d -m 0750 \
        "$STATE_DIR" \
        "$TLS_DIR" \
        "$STACK_DIR" \
        "$RUNTIME_APP_DIR"
}

write_install_state() {
    local last_stage="$1"
    local resume_required="${2:-false}"

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
    local stage="$1"
    local rc

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

app_dir() {
    printf '%s/apps/%s' "$REPO_ROOT" "$1"
}

app_runtime_dir() {
    printf '%s/%s' "$RUNTIME_APP_DIR" "$1"
}

app_compose_file() {
    printf '%s/compose.yml' "$(app_runtime_dir "$1")"
}

load_app_config() {
    local app_id="$1"
    local conf

    unset \
        APP_ID \
        APP_NAME \
        APP_TYPE \
        APP_SOURCE_TYPE \
        APP_SOURCE_URL \
        APP_SOURCE_REF \
        APP_DEPLOY_TYPE \
        APP_SOURCE_COMPOSE \
        APP_SOURCE_SERVICE \
        APP_SOURCE_CONTAINER_PORT \
        APP_SOURCE_ROOT \
        APP_DOMAIN \
        APP_CANONICAL_DOMAIN \
        APP_DOMAIN_ALIASES \
        APP_PORT \
        APP_EXTRA_PORTS \
        APP_CONTAINER \
        APP_TLS_NAME \
        APP_TLS_MODE \
        APP_NGINX_ENABLED \
        APP_CERTIFICATE_ENABLED \
        APP_HEALTHCHECK_URL

    conf="$(app_dir "$app_id")/app.conf"

    [[ -f "$conf" ]] || die "Missing application configuration: $conf"

    source "$conf"

    [[ "${APP_ID:-}" == "$app_id" ]] || \
        die "Application config ${conf} has unexpected APP_ID=${APP_ID:-unset}"

    [[ "${APP_ENABLED:-true}" == "true" ]] || return 1
}

app_ids() {
    local dir
    local app

    shopt -s nullglob

    for dir in "${REPO_ROOT}"/apps/*; do
        [[ -d "$dir" ]] || continue
        [[ -f "$dir/app.conf" ]] || continue
        [[ -f "$dir/install.sh" ]] || continue
        [[ -f "$dir/verify.sh" ]] || continue

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
    local runtime

    runtime="$(app_runtime_dir "$app_id")"

    [[ -f "${runtime}/.installed" ]] || return 1

    load_app_config "$app_id" || return 1

    if [[ "${APP_TYPE:-}" == "custom" ]]; then
        return 0
    fi

    [[ -f "$(app_compose_file "$app_id")" ]]
}

app_is_running() {
    local app_id="$1"
    local container
    local runtime

    load_app_config "$app_id" || return 1

    runtime="$(app_runtime_dir "$app_id")"

    if [[ "${APP_TYPE:-}" == "custom" ]]; then
        case "${APP_DEPLOY_TYPE:-}" in
            static)
                [[ -d "${runtime}/www" ]] || return 1
                [[ -n "${APP_HEALTHCHECK_URL:-}" ]] || return 0
                curl -fsS --max-time 10 \
                    "$APP_HEALTHCHECK_URL" >/dev/null
                ;;
            compose)
                docker compose -f "${runtime}/compose.yml" \
                    ps --status running --services 2>/dev/null |
                    grep -q .
                ;;
            dockerfile)
                container="${APP_CONTAINER:-$APP_ID}"
                [[ "$(docker inspect -f '{{.State.Running}}' \
                    "$container" 2>/dev/null)" == "true" ]]
                ;;
            *)
                return 1
                ;;
        esac
        return
    fi

    container="${APP_CONTAINER:-$APP_ID}"

    docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null |
        grep -qx true
}

app_prepare_runtime() {
    local app_id="$1"
    local source_dir
    local runtime

    load_app_config "$app_id"

    [[ "${APP_TYPE:-}" == "custom" ]] && return 0

    source_dir="$(app_dir "$app_id")"
    runtime="$(app_runtime_dir "$app_id")"

    install -d -m 0750 "$runtime"

    cp "$source_dir/compose.yml" "$(app_compose_file "$app_id")"

    if [[ -f "$source_dir/.env.example" ]]; then
        cp "$source_dir/.env.example" "$runtime/.env.example"
    fi
}

app_config_signature() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "${APP_DOMAIN}" \
        "${APP_PORT}" \
        "${APP_EXTRA_PORTS:-}" \
        "${APP_NGINX_ENABLED:-true}" \
        "${APP_CERTIFICATE_ENABLED:-true}" \
        "${APP_TYPE:-}" \
        "${APP_DEPLOY_TYPE:-}" \
        "${APP_TLS_MODE:-}" \
        "${APP_CANONICAL_DOMAIN:-}" \
        "${APP_DOMAIN_ALIASES:-}"
}

app_is_current() {
    local app_id="$1"
    local runtime
    local source_dir
    local source_hash

    runtime="$(app_runtime_dir "$app_id")"
    source_dir="$(app_dir "$app_id")"

    [[ -f "${runtime}/.config" ]] || return 1
    [[ "$(cat "${runtime}/.config")" == "$(app_config_signature)" ]] || return 1

    load_app_config "$app_id"

    if [[ "${APP_TYPE:-}" == "custom" ]]; then
        [[ -d "${runtime}/source" ]] || return 1
        source_hash="$(find "${runtime}/source" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
        [[ -f "${runtime}/.source.sha256" ]] || return 1
        [[ "$(cat "${runtime}/.source.sha256")" == "$source_hash" ]]
        return
    fi

    [[ -f "${runtime}/.compose.sha256" ]] || return 1
    [[ "$(cat "${runtime}/.compose.sha256")" == "$(sha256sum "${source_dir}/compose.yml" | awk '{print $1}')" ]]
}

app_write_state() {
    local app_id="$1"
    local runtime
    local source_dir
    local source_hash

    runtime="$(app_runtime_dir "$app_id")"
    source_dir="$(app_dir "$app_id")"

    printf '%s' "$(app_config_signature)" > "${runtime}/.config"

    load_app_config "$app_id"

    if [[ "${APP_TYPE:-}" == "custom" ]]; then
        source_hash="$(find "${runtime}/source" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
        printf '%s' "$source_hash" > "${runtime}/.source.sha256"
        rm -f "${runtime}/.compose.sha256"
        chmod 600 "${runtime}/.config" "${runtime}/.source.sha256"
    else
        sha256sum "${source_dir}/compose.yml" |
            awk '{print $1}' > "${runtime}/.compose.sha256"

        chmod 600 \
            "${runtime}/.config" \
            "${runtime}/.compose.sha256"
    fi

    touch "${runtime}/.installed"
    chmod 600 "${runtime}/.installed"
}

app_compose_up() {
    local app_id="$1"
    local runtime
    local compose

    runtime="$(app_runtime_dir "$app_id")"
    compose="$(app_compose_file "$app_id")"

    if [[ "${RECONFIGURE:-false}" == "true" ]]; then
        (
            cd "$runtime"
            docker compose -f "$compose" up -d --force-recreate
        )
    else
        (
            cd "$runtime"
            docker compose -f "$compose" up -d
        )
    fi
}

app_compose_pull() {
    local app_id="$1"
    local runtime
    local compose

    runtime="$(app_runtime_dir "$app_id")"
    compose="$(app_compose_file "$app_id")"

    (
        cd "$runtime"
        docker compose -f "$compose" pull
    )
}

app_compose_ps() {
    local app_id="$1"
    local runtime
    local compose

    runtime="$(app_runtime_dir "$app_id")"
    compose="$(app_compose_file "$app_id")"

    (
        cd "$runtime"
        docker compose -f "$compose" ps
    )
}

install_app() {
    local app_id="$1"

    [[ -x "$(app_dir "$app_id")/install.sh" ]] ||
        chmod +x "$(app_dir "$app_id")/install.sh"

    bash "$(app_dir "$app_id")/install.sh"
}

verify_app() {
    local app_id="$1"

    [[ -x "$(app_dir "$app_id")/verify.sh" ]] ||
        chmod +x "$(app_dir "$app_id")/verify.sh"

    bash "$(app_dir "$app_id")/verify.sh"
}

certificate_mode() {
    [[ "${DOMAIN_MODE}" == "public" ]] &&
        printf 'acme' ||
        printf 'local-ca'
}

public_certificate_name() {
    local zone="${APP_SUBDOMAIN%.}"
    zone="${zone#.}"

    if [[ -n "$zone" ]]; then
        printf '%s.%s' "$zone" "$BASE_DOMAIN"
    else
        printf '%s' "$BASE_DOMAIN"
    fi
}

public_certificate_path() {
    printf '/etc/letsencrypt/live/%s/fullchain.pem' "$(public_certificate_name)"
}

public_certificate_key_path() {
    printf '/etc/letsencrypt/live/%s/privkey.pem' "$(public_certificate_name)"
}

app_certificate_path() {
    local app_id="$1"

    load_app_config "$app_id" || return 1

    if [[ "${APP_TYPE:-}" == "custom" ]]; then
        case "${APP_TLS_MODE:-local-ca}" in
            acme)
                printf '/etc/letsencrypt/live/%s/fullchain.pem' "$APP_TLS_NAME"
                ;;
            local-ca)
                printf '%s/%s.crt' "$TLS_DIR" "$APP_TLS_NAME"
                ;;
            none)
                return 0
                ;;
            *)
                die "Unsupported application TLS mode: ${APP_TLS_MODE}"
                ;;
        esac
    fi

    if [[ "$DOMAIN_MODE" == "public" ]]; then
        public_certificate_path
    else
        printf '%s/%s.crt' "$TLS_DIR" "$APP_TLS_NAME"
    fi
}

app_certificate_key_path() {
    local app_id="$1"

    load_app_config "$app_id" || return 1

    if [[ "${APP_TYPE:-}" == "custom" ]]; then
        case "${APP_TLS_MODE:-local-ca}" in
            acme)
                printf '/etc/letsencrypt/live/%s/privkey.pem' "$APP_TLS_NAME"
                ;;
            local-ca)
                printf '%s/%s.key' "$TLS_DIR" "$APP_TLS_NAME"
                ;;
            none)
                return 0
                ;;
            *)
                die "Unsupported application TLS mode: ${APP_TLS_MODE}"
                ;;
        esac
    fi

    if [[ "$DOMAIN_MODE" == "public" ]]; then
        public_certificate_key_path
    else
        printf '%s/%s.key' "$TLS_DIR" "$APP_TLS_NAME"
    fi
}

infra_certificate_path() {
    local name="$1"
    local domain_var="$2"

    if [[ "$DOMAIN_MODE" == "public" ]]; then
        public_certificate_path
    else
        printf '%s/%s.crt' "$TLS_DIR" "$name"
    fi
}

infra_certificate_key_path() {
    local name="$1"
    local domain_var="$2"

    if [[ "$DOMAIN_MODE" == "public" ]]; then
        public_certificate_key_path
    else
        printf '%s/%s.key' "$TLS_DIR" "$name"
    fi
}

app_nginx_install() {
    local app_id="$1"
    local source_conf
    local runtime_conf
    local cert=""
    local key=""
    local source_root

    source_conf="$(app_dir "$app_id")/nginx.conf"
    runtime_conf="${NGINX_RUNTIME_DIR}/${app_id}.conf"

    if [[ "${APP_NGINX_ENABLED:-true}" != "true" ]]; then
        rm -f "$runtime_conf"
        return 0
    fi

    if [[ ! -f "$source_conf" ]]; then
        warn "Nginx template is missing for ${app_id}: ${source_conf}"
        rm -f "$runtime_conf"
        return 1
    fi

    if [[ "${APP_CERTIFICATE_ENABLED:-true}" == "true" ]]; then
        cert="$(app_certificate_path "$app_id")"
        key="$(app_certificate_key_path "$app_id")"

        [[ -n "$cert" && -n "$key" ]] || {
            warn "Certificate paths are not configured for ${app_id}."
            return 1
        }
    fi

    source_root="$(app_runtime_dir "$app_id")/public"

    if [[ "${APP_TYPE:-}" == "custom" &&
          "${APP_DEPLOY_TYPE:-}" == "static" ]]; then
        source_root="$(app_runtime_dir "$app_id")/www"
    fi

    install -d -m 0755 "$NGINX_RUNTIME_DIR"

    sed \
        -e "s|__APP_DOMAIN__|${APP_DOMAIN}|g" \
        -e "s|__APP_CANONICAL_DOMAIN__|${APP_CANONICAL_DOMAIN:-$APP_DOMAIN}|g" \
        -e "s|__APP_DOMAIN_ALIASES__|${APP_DOMAIN_ALIASES:-}|g" \
        -e "s|__APP_PORT__|${APP_PORT}|g" \
        -e "s|__APP_TLS_NAME__|${APP_TLS_NAME:-$app_id}|g" \
        -e "s|__APP_CERTIFICATE__|${cert}|g" \
        -e "s|__APP_CERTIFICATE_KEY__|${key}|g" \
        -e "s|__APP_SOURCE_ROOT__|${source_root}|g" \
        -e "s|__APP_TLS_ENABLED__|${APP_CERTIFICATE_ENABLED:-true}|g" \
        "$source_conf" > "$runtime_conf"
}

app_nginx_remove() {
    rm -f "${NGINX_RUNTIME_DIR}/$1.conf"
}

app_certificate_needed() {
    [[ "${APP_CERTIFICATE_ENABLED:-true}" == "true" ]]
}

app_cert_install() {
    local app_id="$1"

    load_app_config "$app_id" || return 1

    if [[ "${APP_CERTIFICATE_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    local cert
    local key

    cert="$(app_certificate_path "$app_id")"
    key="$(app_certificate_key_path "$app_id")"

    [[ -s "$cert" && -s "$key" ]]
}

sleep_after_disconnect_warning() {
    echo
    warn "The previous operation may disconnect your current SSH/Cockpit session."
    warn "After reconnecting, run: sudo ${STACK_DIR}/install.sh"
    echo
}