#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/scripts/00-common.sh"

require_root
require_fedora
load_config
ensure_dirs

SELECTION_FILE="${STATE_DIR}/selected-apps.env"

RECONFIGURE="${RECONFIGURE:-false}"
DOMAIN_RECONFIGURE="${DOMAIN_RECONFIGURE:-false}"
PROXMOX_RECONFIGURE="${PROXMOX_RECONFIGURE:-false}"
NETWORK_RECONFIGURE="${NETWORK_RECONFIGURE:-false}"
APP_RECONFIGURE="${APP_RECONFIGURE:-false}"
GODADDY_RECONFIGURE="${GODADDY_RECONFIGURE:-false}"

RUNTIME_SOURCE_DIR="/opt/fedora-server-sources"
UPDATE_SCRIPT="/usr/local/sbin/update-app.sh"

usage() {
    cat <<'USAGE'
Fedora Server Home Services Setup

Usage:
  sudo ./install.sh
  sudo ./install.sh --all
  sudo ./install.sh --app NAME
  sudo ./install.sh --reconfigure
  sudo ./install.sh --reconfigure-domain
  sudo ./install.sh --list
  sudo ./install.sh --help

Options:
  --all                    Install/update all applications
  --app NAME               Install/update one application
  --reconfigure            Re-apply saved configuration
  --reconfigure-domain     Change saved domain/TLS settings
  --list                   Show detected and available applications
  --help                   Show this help

Public mode uses one Let's Encrypt certificate containing the application-zone
apex and wildcard, validated through the GoDaddy DNS-01 API.
USAGE
}

state_exists() {
    [[ -d "$STATE_DIR" ]] &&
        find "$STATE_DIR" -maxdepth 1 -type f -print -quit 2>/dev/null |
        grep -q .
}

detected_app_ids() {
    local app_id

    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue
        app_is_installed "$app_id" && printf '%s\n' "$app_id"
    done < <(app_ids)
}

detected_app_count() {
    detected_app_ids | grep -c . || true
}

show_domain_state() {
    if [[ ! -f "$DOMAIN_STATE" ]]; then
        echo "Domain/TLS:"
        echo "  Status      : not configured"
        return
    fi

    load_domain_state

    echo "Domain/TLS:"
    echo "  Mode        : ${DOMAIN_MODE}"

    if [[ "$DOMAIN_MODE" == "public" ]]; then
        echo "  Base domain : ${BASE_DOMAIN}"
        echo "  App prefix  : ${APP_SUBDOMAIN}"
        echo "  App zone    : ${APP_SUBDOMAIN}.${BASE_DOMAIN}"
        echo "  ACME email  : ${ACME_EMAIL:-not set}"
    else
        echo "  App prefix  : ${APP_SUBDOMAIN}"
    fi
}

show_network_state() {
    echo "Network:"

    if [[ ! -f "$NETWORK_STATE" ]]; then
        echo "  Status      : not configured"
        return
    fi

    unset CONNECTION_NAME INTERFACE STATIC_IP PREFIX GATEWAY DNS_SERVER

    source "$NETWORK_STATE"

    echo "  Connection  : ${CONNECTION_NAME:-not set}"
    echo "  Interface   : ${INTERFACE:-not set}"
    echo "  IPv4        : ${STATIC_IP:-not set}/${PREFIX:-?}"
    echo "  Gateway     : ${GATEWAY:-not set}"
    echo "  DNS         : ${DNS_SERVER:-not set}"
}

show_proxmox_state() {
    echo "Proxmox:"

    if [[ ! -f "$PROXMOX_STATE" ]]; then
        echo "  Backend IP  : not configured"
        return
    fi

    unset PROXMOX_IP

    source "$PROXMOX_STATE"

    echo "  Backend IP  : ${PROXMOX_IP:-not set}"
}

show_application_selection() {
    echo "Application selection:"

    if [[ ! -f "$SELECTION_FILE" ]]; then
        echo "  Saved       : not configured"
        return
    fi

    unset SELECTED_APPS
    source "$SELECTION_FILE"

    if [[ -n "${SELECTED_APPS:-}" ]]; then
        local app_id

        for app_id in $SELECTED_APPS; do
            if load_app_config "$app_id"; then
                printf '  - %s (%s)\n' "$APP_NAME" "$app_id"
            else
                printf '  - %s\n' "$app_id"
            fi
        done
    else
        echo "  Saved       : none"
    fi
}

show_godaddy_state() {
    echo "GoDaddy PAT:"

    if godaddy_credentials_valid; then
        echo "  Status      : configured (value hidden)"
    else
        echo "  Status      : not configured"
    fi
}

show_detection() {
    local count

    count="$(detected_app_count)"

    echo
    echo "========================================"
    echo " Existing installation detection"
    echo "========================================"
    echo

    if (( count == 0 )) && ! state_exists; then
        echo "No installed applications were detected."
        echo "No saved installer settings were detected."
        echo
        echo "This is treated as a new installation."
        echo "You will go through the complete configuration"
        echo "and application selection process."
        return
    fi

    if (( count > 0 )); then
        echo "Detected installed applications:"

        while IFS= read -r app_id; do
            [[ -n "$app_id" ]] || continue

            if load_app_config "$app_id"; then
                printf '  - %s (%s)\n' "$APP_NAME" "$app_id"
            fi
        done < <(detected_app_ids)
    else
        echo "No installed applications were detected."
    fi

    echo
    show_domain_state

    echo
    show_network_state

    echo
    show_proxmox_state

    echo
    show_application_selection

    echo
    show_godaddy_state
}

save_selection() {
    local selected="$1"

    cat > "$SELECTION_FILE" <<EOFSEL
SELECTED_APPS=$(printf '%q' "$selected")
EOFSEL

    chmod 600 "$SELECTION_FILE"
}

show_apps() {
    local app_id

    echo
    echo "Available applications:"

    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue

        if load_app_config "$app_id"; then
            printf '  - %s (%s, host port %s)\n' \
                "$APP_NAME" \
                "$APP_ID" \
                "${APP_PORT:-not set}"
        fi
    done < <(app_ids)

    echo
}

validate_app_id() {
    local app_id="$1"

    [[ -d "$(app_dir "$app_id")" ]] ||
        die "Unknown application: $app_id"

    [[ -f "$(app_dir "$app_id")/app.conf" ]] ||
        die "Application is incomplete: $app_id"

    [[ -f "$(app_dir "$app_id")/install.sh" ]] ||
        die "Application is incomplete: $app_id"

    [[ -f "$(app_dir "$app_id")/verify.sh" ]] ||
        die "Application is incomplete: $app_id"

    load_app_config "$app_id" ||
        die "Application is disabled: $app_id"

    if [[ "${APP_TYPE:-}" != "custom" ]]; then
        [[ -f "$(app_dir "$app_id")/compose.yml" ]] ||
            die "Application is incomplete: $app_id"
    fi
}

write_domain_state_interactive() {
    local answer
    local mode
    local base
    local prefix
    local email

    if [[ -f "$DOMAIN_STATE" && "$DOMAIN_RECONFIGURE" != true ]]; then
        load_domain_state
        ensure_godaddy_credentials
        return
    fi

    echo
    echo "========================================"
    echo " HTTPS / domain configuration"
    echo "========================================"
    echo
    echo "Public mode gives normal browser-trusted HTTPS through Let's Encrypt."
    echo "Local mode uses a private CA that must be trusted on each client device."
    echo

    read -r -p "Use public trusted HTTPS with a real domain? [y/N]: " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        mode="public"
        DOMAIN_MODE="$mode"

        read -r -p \
            "What is the base domain you control, e.g. example.com? " \
            base

        base="${base%.}"

        [[ -n "$base" ]] ||
            die "Base domain cannot be empty."

        valid_hostname "$base" ||
            die "Invalid base domain: $base"

        read -r -p \
            "What application subdomain prefix should be used, e.g. home? [home]: " \
            prefix

        APP_SUBDOMAIN="${prefix:-home}"

        valid_domain_prefix "$APP_SUBDOMAIN" ||
            die "Invalid application subdomain prefix: $APP_SUBDOMAIN"

        read -r -p \
            "What email should Let's Encrypt use for certificate notices? Press Enter to skip: " \
            email

        ACME_EMAIL="$email"
        BASE_DOMAIN="$base"

        save_domain_state
        load_domain_state
        ensure_godaddy_credentials
    else
        DOMAIN_MODE="local"
        BASE_DOMAIN=""
        APP_SUBDOMAIN="home"
        ACME_EMAIL=""

        save_domain_state
        load_domain_state
    fi
}

select_apps_interactive() {
    local app_id
    local answer
    local selected=""

    echo
    echo "========================================"
    echo " Application selection"
    echo "========================================"
    echo
    echo "Each question asks whether this application should be managed."
    echo

    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue

        if ! load_app_config "$app_id"; then
            continue
        fi

        read -r -p \
            "Install/update ${APP_NAME} (${APP_DOMAIN}, host port ${APP_PORT})? [y/N]: " \
            answer

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            selected+="${selected:+ }${app_id}"
        fi
    done < <(app_ids)

    save_selection "$selected"
    SELECTED_APPS_RESULT="$selected"
}

show_plan() {
    local selected="$1"
    local app_id

    echo
    echo "========================================"
    echo " Planned operation"
    echo "========================================"
    echo

    echo "Domain/TLS mode: ${DOMAIN_MODE}"

    if [[ "$DOMAIN_MODE" == "public" ]]; then
        echo "Base domain: ${BASE_DOMAIN}"
        echo "Application zone: ${APP_SUBDOMAIN}.${BASE_DOMAIN}"
        echo "Certificate: ${APP_SUBDOMAIN}.${BASE_DOMAIN} + *.${APP_SUBDOMAIN}.${BASE_DOMAIN}"
    fi

    echo
    echo "Selected applications:"

    if [[ -n "$selected" ]]; then
        for app_id in $selected; do
            if load_app_config "$app_id"; then
                printf '  - %s (%s -> port %s)\n' \
                    "$APP_NAME" \
                    "$APP_DOMAIN" \
                    "${APP_PORT:-not set}"
            fi
        done
    else
        echo "  - none"
    fi

    echo
    echo "Settings selected for modification:"

    [[ "$DOMAIN_RECONFIGURE" == true ]] &&
        echo "  - HTTPS / domain settings"

    [[ "$PROXMOX_RECONFIGURE" == true ]] &&
        echo "  - Proxmox backend IP"

    [[ "$NETWORK_RECONFIGURE" == true ]] &&
        echo "  - Network settings"

    [[ "$APP_RECONFIGURE" == true ]] &&
        echo "  - Application selection"

    [[ "$GODADDY_RECONFIGURE" == true ]] &&
        echo "  - GoDaddy PAT"

    if [[ "$DOMAIN_RECONFIGURE" != true &&
          "$PROXMOX_RECONFIGURE" != true &&
          "$NETWORK_RECONFIGURE" != true &&
          "$APP_RECONFIGURE" != true &&
          "$GODADDY_RECONFIGURE" != true ]]; then
        echo "  - none"
    fi

    echo
}

check_updates_first() {
    local rc
    local answer

    set +e
    dnf -q check-update >/dev/null 2>&1
    rc=$?
    set -e

    case "$rc" in
        0)
            log "No pending Fedora package updates detected."
            ;;
        100)
            warn "Fedora has pending updates."

            read -r -p \
                "Install available Fedora updates now and stop so you can reboot if needed? [Y/n]: " \
                answer

            answer="${answer:-Y}"

            [[ "$answer" =~ ^[Yy]$ ]] ||
                die "Installation cannot continue while Fedora updates are pending."

            dnf upgrade -y

            warn "If Fedora requires a reboot, reboot now, then run the installer again."
            exit 0
            ;;
        *)
            die "Unable to determine Fedora update state (dnf exit code $rc)."
            ;;
    esac
}

run_installation() {
    local selected="$1"
    local app_id

    check_updates_first

    export RECONFIGURE
    export DOMAIN_RECONFIGURE
    export PROXMOX_RECONFIGURE
    export NETWORK_RECONFIGURE
    export APP_RECONFIGURE
    export GODADDY_RECONFIGURE

    run_stage 01-system.sh
    run_stage 02-proxmox.sh
    run_stage 03-network.sh
    run_stage 04-docker.sh
    run_stage 40-certificates.sh
    run_stage 05-nginx.sh

    for app_id in $selected; do
        validate_app_id "$app_id"

        write_install_state "app:$app_id" false

        log "Installing/updating application: $app_id"

        install_app "$app_id"
    done

    write_install_state 99-verify false

    bash "${SCRIPT_DIR}/scripts/99-verify.sh"

    clear_install_state

    echo
    echo "Installation/update completed."
}

update_installed() {
    local selected
    local answer

    load_domain_state

    if [[ -f "$SELECTION_FILE" ]]; then
        source "$SELECTION_FILE"
    fi

    selected="${SELECTED_APPS:-$(detected_app_ids | paste -sd ' ' -)}"

    if [[ -z "$selected" ]]; then
        echo
        echo "No installed applications were detected."
        echo "Choose settings mode to configure applications."
        return
    fi

    read -r -p \
        "Update the saved installation and reconcile its configuration now? [Y/n]: " \
        answer

    answer="${answer:-Y}"

    [[ "$answer" =~ ^[Yy]$ ]] || return

    RECONFIGURE=false
    DOMAIN_RECONFIGURE=false
    PROXMOX_RECONFIGURE=false
    NETWORK_RECONFIGURE=false
    APP_RECONFIGURE=false
    GODADDY_RECONFIGURE=false

    validate_config
    show_plan "$selected"

    run_installation "$selected"
}

settings_selection_menu() {
    local choice

    DOMAIN_RECONFIGURE=false
    PROXMOX_RECONFIGURE=false
    NETWORK_RECONFIGURE=false
    APP_RECONFIGURE=false
    GODADDY_RECONFIGURE=false

    echo
    echo "========================================"
    echo " Settings to modify"
    echo "========================================"
    echo
    echo "Choose exactly which saved settings should be changed."
    echo "You can select \"all\" to walk through every configurable setting."
    echo
    echo "  1) HTTPS / domain settings"
    echo "  2) Proxmox backend IP"
    echo "  3) Network settings"
    echo "  4) Application selection"
    echo "  5) GoDaddy PAT"
    echo "  6) All settings"
    echo "  7) Cancel"
    echo

    read -r -p "Choose one option [1-7]: " choice

    case "$choice" in
        1) DOMAIN_RECONFIGURE=true ;;
        2) PROXMOX_RECONFIGURE=true ;;
        3) NETWORK_RECONFIGURE=true ;;
        4) APP_RECONFIGURE=true ;;
        5) GODADDY_RECONFIGURE=true ;;
        6)
            DOMAIN_RECONFIGURE=true
            PROXMOX_RECONFIGURE=true
            NETWORK_RECONFIGURE=true
            APP_RECONFIGURE=true
            GODADDY_RECONFIGURE=true
            ;;
        7) return 1 ;;
        *) die "Invalid settings selection: $choice" ;;
    esac

    return 0
}

modify_godaddy_pat() {
    local pat

    echo
    echo "========================================"
    echo " GoDaddy PAT configuration"
    echo "========================================"
    echo
    echo "The PAT value is never displayed after it is saved."
    echo

    read -r -s \
        -p "New GoDaddy PAT (leave empty to cancel): " \
        pat

    echo

    if [[ -z "$pat" ]]; then
        echo "GoDaddy PAT change cancelled."
        return
    fi

    save_godaddy_credentials "$pat"
    unset pat

    echo "GoDaddy PAT saved. The value remains hidden."
}

create_custom_app() {
    local name id url ref archive deploy compose service port root
    local domain aliases canonical tls host_port container health
    local appdir

    echo
    echo "========================================"
    echo " Create a custom application"
    echo "========================================"
    echo

    read -r -p "Application name: " name
    [[ -n "$name" ]] || die "Application name cannot be empty."

    read -r -p "Application ID (lowercase letters, numbers, hyphens): " id
    [[ "$id" =~ ^[a-z0-9][a-z0-9-]{1,47}$ ]] ||
        die "Invalid application ID."

    appdir="$(app_dir "$id")"
    [[ ! -e "$appdir" ]] ||
        die "An application with ID '$id' already exists."

    read -r -p "Forgejo repository URL: " url
    [[ "$url" =~ ^https?://[^[:space:]]+$ ]] ||
        die "Enter a valid HTTP(S) repository URL."
    url="${url%/}"

    read -r -p "Repository branch, tag, or ref [main]: " ref
    ref="${ref:-main}"
    [[ "$ref" != *".."* ]] || die "Invalid repository ref."

    archive="${url}/archive/${ref}.tar.gz"

    echo "Checking repository archive access with curl..."
    if ! curl -fLsS --connect-timeout 15 --max-time 45 "$archive" -o /dev/null; then
        echo "The repository archive is not accessible:"
        echo "$archive"
        echo "Check the repository URL and ref, then try again."
        echo "Repositories requiring an authentication token are not supported."
        return 1
    fi

    echo
    echo "Deployment type:"
    echo "  1) Static site"
    echo "  2) Compose"
    echo "  3) Dockerfile"
    read -r -p "Choose deployment type [2]: " deploy
    deploy="${deploy:-2}"

    case "$deploy" in
        1)
            deploy="static"
            compose=""
            service=""
            read -r -p "Static output directory inside the repository [./]: " root
            root="${root:-.}"
            read -r -p "Local host port [8080]: " port
            port="${port:-8080}"
            ;;
        2)
            deploy="compose"
            read -r -p "Compose file path inside the repository [compose.yml]: " compose
            compose="${compose:-compose.yml}"
            read -r -p "Compose service name: " service
            read -r -p "Container web port [8080]: " port
            port="${port:-8080}"
            root=""
            ;;
        3)
            deploy="dockerfile"
            compose=""
            service=""
            read -r -p "Build context directory inside the repository [.]: " root
            root="${root:-.}"
            read -r -p "Container port [8080]: " port
            port="${port:-8080}"
            ;;
        *)
            die "Invalid deployment type."
            ;;
    esac

    valid_port "$port" || die "Invalid application port."

    read -r -p "Primary domain: " domain
    valid_hostname "$domain" || die "Invalid application domain."

    read -r -p "Additional domain aliases, space-separated (optional): " aliases
    read -r -p "Canonical domain [$domain]: " canonical
    canonical="${canonical:-$domain}"
    valid_hostname "$canonical" || die "Invalid canonical domain."

    echo
    echo "TLS mode:"
    echo "  1) Public ACME certificate"
    echo "  2) Local CA certificate"
    echo "  3) No certificate"
    read -r -p "Choose TLS mode [2]: " tls
    tls="${tls:-2}"

    case "$tls" in
        1) tls="acme" ;;
        2) tls="local-ca" ;;
        3) tls="none" ;;
        *) die "Invalid TLS mode." ;;
    esac

    read -r -p "Local host port [$port]: " host_port
    host_port="${host_port:-$port}"
    valid_port "$host_port" || die "Invalid host port."

    read -r -p "Container name [$id]: " container
    container="${container:-$id}"

    read -r -p "Health-check URL (optional): " health

    install -d -m 0750 "$appdir"

    cat > "${appdir}/app.conf" <<EOF_APP
APP_ID=$(printf '%q' "$id")
APP_NAME=$(printf '%q' "$name")
APP_TYPE="custom"
APP_SOURCE_TYPE="forgejo"
APP_SOURCE_URL=$(printf '%q' "$url")
APP_SOURCE_REF=$(printf '%q' "$ref")
APP_DEPLOY_TYPE=$(printf '%q' "$deploy")
APP_SOURCE_COMPOSE=$(printf '%q' "$compose")
APP_SOURCE_SERVICE=$(printf '%q' "$service")
APP_SOURCE_CONTAINER_PORT=$(printf '%q' "$port")
APP_SOURCE_ROOT=$(printf '%q' "$root")
APP_DOMAIN=$(printf '%q' "$domain")
APP_DOMAIN_ALIASES=$(printf '%q' "$aliases")
APP_CANONICAL_DOMAIN=$(printf '%q' "$canonical")
APP_TLS_MODE=$(printf '%q' "$tls")
APP_PORT=$(printf '%q' "$host_port")
APP_CONTAINER=$(printf '%q' "$container")
APP_TLS_NAME=$(printf '%q' "$id")
APP_NGINX_ENABLED="true"
APP_CERTIFICATE_ENABLED=$( [[ "$tls" == "none" ]] && printf '"false"' || printf '"true"' )
APP_HEALTHCHECK_URL=$(printf '%q' "$health")
EOF_APP

    cat > "${appdir}/install.sh" <<'EOF_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/00-common.sh"
app_id="$(basename "$(dirname "${BASH_SOURCE[0]}")")"
source "$(app_dir "$app_id")/app.conf"
runtime="$(app_runtime_dir "$app_id")"
source_root="/opt/fedora-server-sources/${app_id}"
install -d -m 0750 "$runtime" "$source_root"
archive="${APP_SOURCE_URL%/}/archive/${APP_SOURCE_REF}.tar.gz"
curl -fLsS --retry 2 --connect-timeout 15 "$archive" -o "${source_root}/source.tar.gz"
tar -tzf "${source_root}/source.tar.gz" >/dev/null
install -d -m 0750 "${source_root}/unpacked"
find "${source_root}/unpacked" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
tar -xzf "${source_root}/source.tar.gz" -C "${source_root}/unpacked" --strip-components=1
case "$APP_DEPLOY_TYPE" in
    static)
        root="${source_root}/unpacked/${APP_SOURCE_ROOT}"
        [[ -d "$root" ]] || root="${source_root}/unpacked"
        install -d -m 0755 "${runtime}/www"
        find "${runtime}/www" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        cp -a "$root"/. "${runtime}/www"/
        ;;
    compose)
        compose="${source_root}/unpacked/${APP_SOURCE_COMPOSE}"
        [[ -f "$compose" ]] || { printf 'Compose file not found: %s\n' "$compose" >&2; exit 1; }
        cp "$compose" "${runtime}/source-compose.yml"
        printf '%s\n' "$APP_SOURCE_SERVICE" > "${runtime}/source-service"
        printf '%s\n' "$APP_SOURCE_CONTAINER_PORT" > "${runtime}/container-port"
        printf '%s\n' "$APP_DOMAIN" > "${runtime}/domain"
        printf '%s\n' "$APP_PORT" > "${runtime}/host-port"
        printf '%s\n' "$APP_CONTAINER" > "${runtime}/container-name"
        cp "${runtime}/source-compose.yml" "${runtime}/compose.yml"
        docker compose -f "${runtime}/compose.yml" config >/dev/null
        docker compose -f "${runtime}/compose.yml" up -d
        ;;
    dockerfile)
        root="${source_root}/unpacked/${APP_SOURCE_ROOT}"
        [[ -d "$root" ]] || root="${source_root}/unpacked"
        if [[ ! -f "${root}/Dockerfile" ]]; then
            printf 'No Dockerfile found in %s.\n' "$root" >&2
            printf 'Create it manually using mkdir -p and cat > Dockerfile <<'\''EOF'\''.\n' >&2
            printf 'The wizard does not create or modify Dockerfiles.\n' >&2
            exit 2
        fi
        docker build -t "${APP_ID}:local" "$root"
        docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
        docker run -d --restart unless-stopped --name "$APP_CONTAINER" -p "127.0.0.1:${APP_PORT}:${APP_SOURCE_CONTAINER_PORT}" "${APP_ID}:local"
        ;;
    *)
        printf 'Unsupported deployment type: %s\n' "$APP_DEPLOY_TYPE" >&2
        exit 1
        ;;
esac
touch "${runtime}/.installed"
chmod 600 "${runtime}/.installed"
EOF_INSTALL
    chmod 750 "${appdir}/install.sh"

    cat > "${appdir}/verify.sh" <<'EOF_VERIFY'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/00-common.sh"
app_id="$(basename "$(dirname "${BASH_SOURCE[0]}")")"
source "$(app_dir "$app_id")/app.conf"
if [[ -n "${APP_HEALTHCHECK_URL:-}" ]]; then
    curl -fsS --max-time 10 "$APP_HEALTHCHECK_URL" >/dev/null
fi
EOF_VERIFY
    chmod 750 "${appdir}/verify.sh"

    cat > "${appdir}/remove.sh" <<'EOF_REMOVE'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/00-common.sh"
app_id="$(basename "$(dirname "${BASH_SOURCE[0]}")")"
source "$(app_dir "$app_id")/app.conf"
runtime="$(app_runtime_dir "$app_id")"
if [[ "${APP_DEPLOY_TYPE:-}" == "compose" && -f "${runtime}/compose.yml" ]]; then
    docker compose -f "${runtime}/compose.yml" down --remove-orphans
elif [[ -n "${APP_CONTAINER:-}" ]]; then
    docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
fi
rm -f "${NGINX_RUNTIME_DIR}/${app_id}.conf"
EOF_REMOVE
    chmod 750 "${appdir}/remove.sh"

    echo
    echo "Created application definition: apps/${id}"
    echo "No Dockerfile was created or modified."
}

update_one_source() {
    local app_id="$1"
    local url ref archive destination

    load_app_config "$app_id" || {
        warn "Application is disabled: $app_id"
        return 1
    }

    url="${APP_SOURCE_URL:-}"
    ref="${APP_SOURCE_REF:-}"

    if [[ -z "$url" || -z "$ref" ]]; then
        warn "$app_id is not configured for source-only updates."
        return 1
    fi

    archive="${url%/}/archive/${ref}.tar.gz"
    destination="${RUNTIME_SOURCE_DIR}/${app_id}"

    install -d -m 0750 "$destination"

    if ! curl -fLsS --retry 2 --connect-timeout 15 --max-time 60 \
        "$archive" -o "${destination}/source-update.tar.gz"; then
        warn "Could not download the source archive for $app_id."
        return 1
    fi

    if ! tar -tzf "${destination}/source-update.tar.gz" >/dev/null; then
        warn "The downloaded archive for $app_id is invalid."
        rm -f "${destination}/source-update.tar.gz"
        return 1
    fi

    log "Source archive staged for $app_id at ${destination}/source-update.tar.gz"
    log "The running application was not deployed, restarted, or changed."
}

update_source_only() {
    local choice app_id
    local selected=()

    echo
    echo "========================================"
    echo " Update application source only"
    echo "========================================"
    echo
    echo "This downloads source archives only. It does not deploy or restart applications."
    show_apps

    read -r -p "Application ID, All, or Cancel: " choice

    case "$choice" in
        Cancel|cancel|CANCEL|"")
            echo "Source update cancelled."
            return
            ;;
        All|all|ALL)
            while IFS= read -r app_id; do
                [[ -n "$app_id" ]] && selected+=("$app_id")
            done < <(app_ids)
            ;;
        *)
            validate_app_id "$choice"
            selected+=("$choice")
            ;;
    esac

    for app_id in "${selected[@]}"; do
        update_one_source "$app_id" || true
    done
}

install_application() {
    local app_id
    local answer
    local selected
    local installed
    local available=()
    local choice
    local item

    load_domain_state

    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue

        if ! app_is_installed "$app_id"; then
            available+=("$app_id")
        fi
    done < <(app_ids)

    echo
    echo "========================================"
    echo " Install an application"
    echo "========================================"
    echo

    echo "  C) Create a custom application"
    echo

    if ((${#available[@]} == 0)); then
        echo "All available applications are already installed."
        read -r -p "Create a custom application now? [y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            create_custom_app || return
            return
        fi
        return
    fi

    echo "Applications available for installation:"
    echo

    for item in "${!available[@]}"; do
        app_id="${available[$item]}"

        load_app_config "$app_id"

        printf '  %d) %s (%s, host port %s)\n' \
            "$((item + 1))" \
            "$APP_NAME" \
            "$APP_ID" \
            "${APP_PORT:-not set}"
    done

    echo
    echo "Enter one or more numbers separated by spaces."
    echo "Enter C to create a custom application."
    echo "Example: 1 3"
    echo

    read -r -p "Choose applications to install: " choice

    if [[ "$choice" =~ ^[Cc]$ ]]; then
        create_custom_app || return
        return
    fi

    [[ -n "$choice" ]] ||
        die "No application was selected."

    selected=""

    for item in $choice; do
        [[ "$item" =~ ^[0-9]+$ ]] ||
            die "Invalid application selection: $item"

        ((item >= 1 && item <= ${#available[@]})) ||
            die "Application selection is outside the available range: $item"

        app_id="${available[$((item - 1))]}"

        if [[ " $selected " == *" $app_id "* ]]; then
            continue
        fi

        selected+="${selected:+ }${app_id}"
    done

    echo
    echo "Applications selected for installation:"

    for app_id in $selected; do
        load_app_config "$app_id"
        printf '  - %s (%s -> port %s)\n' \
            "$APP_NAME" \
            "$APP_DOMAIN" \
            "${APP_PORT:-not set}"
    done

    echo

    read -r -p \
        "Add these applications to the managed installation and install them now? [Y/n]: " \
        answer

    answer="${answer:-Y}"

    [[ "$answer" =~ ^[Yy]$ ]] || {
        echo "Application installation cancelled."
        return
    }

    if [[ -f "$SELECTION_FILE" ]]; then
        unset SELECTED_APPS
        source "$SELECTION_FILE"
    fi

    installed="${SELECTED_APPS:-}"

    for app_id in $selected; do
        if [[ " $installed " != *" $app_id "* ]]; then
            installed+="${installed:+ }${app_id}"
        fi
    done

    save_selection "$installed"

    RECONFIGURE=true
    DOMAIN_RECONFIGURE=false
    PROXMOX_RECONFIGURE=false
    NETWORK_RECONFIGURE=false
    APP_RECONFIGURE=false
    GODADDY_RECONFIGURE=false

    validate_config
    show_plan "$installed"

    run_installation "$installed"
}

modify_settings() {
    local selected
    local answer

    if ! settings_selection_menu; then
        echo "No settings changed."
        return
    fi

    load_domain_state

    if [[ "$DOMAIN_RECONFIGURE" == true ]]; then
        write_domain_state_interactive
        DOMAIN_RECONFIGURE=false
    fi

    if [[ "$APP_RECONFIGURE" == true ]]; then
        select_apps_interactive
        selected="$SELECTED_APPS_RESULT"
        APP_RECONFIGURE=false
    elif [[ -f "$SELECTION_FILE" ]]; then
        source "$SELECTION_FILE"
        selected="${SELECTED_APPS:-}"
    else
        selected="$(detected_app_ids | paste -sd ' ' -)"
    fi

    if [[ "$GODADDY_RECONFIGURE" == true ]]; then
        modify_godaddy_pat
        GODADDY_RECONFIGURE=false
    fi

    RECONFIGURE=true

    validate_config
    show_plan "$selected"

    read -r -p \
        "Continue with the selected settings changes? [Y/n]: " \
        answer

    answer="${answer:-Y}"

    [[ "$answer" =~ ^[Yy]$ ]] || return

    run_installation "$selected"
}

remove_application() {
    local app_id
    local answer
    local data_answer
    local runtime
    local compose
    local new_selection
    local item

    show_apps

    read -r -p \
        "Which application ID should be removed, e.g. joplin, portainer, or vaultwarden? " \
        app_id

    validate_app_id "$app_id"
    load_app_config "$app_id"

    runtime="$(app_runtime_dir "$app_id")"
    compose="$(app_compose_file "$app_id")"

    read -r -p \
        "Also delete ${APP_NAME}'s persistent Docker volumes and data? [y/N]: " \
        data_answer

    read -r -p \
        "Confirm removal of ${APP_NAME}? [y/N]: " \
        answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Removal cancelled."
        return
    fi

    if [[ -x "$(app_dir "$app_id")/remove.sh" ]]; then
        bash "$(app_dir "$app_id")/remove.sh"
    elif [[ -f "$compose" ]]; then
        (
            cd "$runtime"

            if [[ "$data_answer" =~ ^[Yy]$ ]]; then
                docker compose \
                    -f "$compose" \
                    down \
                    --remove-orphans \
                    --volumes
            else
                docker compose \
                    -f "$compose" \
                    down \
                    --remove-orphans
            fi
        )
    fi

    rm -rf "$runtime"

    app_nginx_remove "$app_id"

    new_selection=""

    if [[ -f "$SELECTION_FILE" ]]; then
        source "$SELECTION_FILE"
    fi

    for item in ${SELECTED_APPS:-}; do
        [[ "$item" == "$app_id" ]] && continue
        new_selection+="${new_selection:+ }$item"
    done

    save_selection "$new_selection"

    if [[ -f "${STATE_DIR}/managed-nginx-apps" ]]; then
        grep -vxF \
            "$app_id" \
            "${STATE_DIR}/managed-nginx-apps" \
            > "${STATE_DIR}/managed-nginx-apps.tmp" ||
            true

        mv \
            "${STATE_DIR}/managed-nginx-apps.tmp" \
            "${STATE_DIR}/managed-nginx-apps"
    fi

    nginx -t >/dev/null 2>&1 &&
        systemctl reload nginx ||
        true

    echo "${APP_NAME} has been removed."
}

remove_server_package() {
    local answer
    local data_answer
    local app_id
    local runtime
    local compose
    local certbot
    local cert_name

    echo
    echo "This removes the repository-managed service package:"
    echo "containers, managed Nginx config, renewal timer, TLS material,"
    echo "installer state and Certbot environment."
    echo
    echo "It does not remove Fedora, Docker packages, unrelated Docker data,"
    echo "router/DNS settings, or this Git repository."
    echo

    read -r -p \
        "Also delete persistent Docker volumes belonging to managed applications? [y/N]: " \
        data_answer

    read -r -p \
        "Confirm removal of the complete managed server package? [y/N]: " \
        answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Removal cancelled."
        return
    fi

    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue

        if ! load_app_config "$app_id"; then
            continue
        fi

        runtime="$(app_runtime_dir "$app_id")"
        compose="$(app_compose_file "$app_id")"

        if [[ -x "$(app_dir "$app_id")/remove.sh" ]]; then
            bash "$(app_dir "$app_id")/remove.sh" || true
        elif [[ -f "$compose" ]]; then
            (
                cd "$runtime"

                if [[ "$data_answer" =~ ^[Yy]$ ]]; then
                    docker compose \
                        -f "$compose" \
                        down \
                        --remove-orphans \
                        --volumes ||
                        true
                else
                    docker compose \
                        -f "$compose" \
                        down \
                        --remove-orphans ||
                        true
                fi
            )
        fi

        rm -rf "$runtime"
    done < <(app_ids)

    rm -f \
        "${NGINX_RUNTIME_DIR}/fedora-server.conf" \
        "${NGINX_RUNTIME_DIR}/proxmox.conf"

    if [[ -f "${STATE_DIR}/managed-nginx-apps" ]]; then
        while IFS= read -r app_id; do
            [[ -n "$app_id" ]] || continue
            rm -f "${NGINX_RUNTIME_DIR}/${app_id}.conf"
        done < "${STATE_DIR}/managed-nginx-apps"
    fi

    rm -f "${STATE_DIR}/managed-nginx-apps"

    systemctl disable --now fedora-server-certbot-renew.timer \
        2>/dev/null ||
        true

    rm -f \
        /etc/systemd/system/fedora-server-certbot-renew.service \
        /etc/systemd/system/fedora-server-certbot-renew.timer

    systemctl daemon-reload

    certbot=""

    if [[ -x "${STACK_DIR}/certbot-venv/bin/certbot" ]]; then
        certbot="${STACK_DIR}/certbot-venv/bin/certbot"
    fi

    if [[ -z "$certbot" ]] && command -v certbot >/dev/null 2>&1; then
        certbot="$(command -v certbot)"
    fi

    if [[ -n "$certbot" ]]; then
        "$certbot" certificates 2>/dev/null |
            awk '/Certificate Name: / {print $3}' |
            while IFS= read -r cert_name; do
                [[ -n "$cert_name" ]] || continue

                "$certbot" delete \
                    --cert-name "$cert_name" \
                    --non-interactive \
                    >/dev/null 2>&1 ||
                    true
            done
    fi

    rm -rf \
        "$TLS_DIR" \
        "$RUNTIME_APP_DIR" \
        "$STACK_DIR/certbot-venv"

    rm -f \
        "$STACK_DIR/godaddy-dns-hook.sh" \
        "$NETWORK_STATE" \
        "$PROXMOX_STATE" \
        "$DOMAIN_STATE" \
        "${STATE_DIR}/domain-previous.env" \
        "$SELECTION_FILE" \
        "$GODADDY_CREDENTIALS" \
        "$INSTALL_STATE"

    nginx -t >/dev/null 2>&1 &&
        systemctl reload nginx ||
        true

    echo "Managed server package removal completed."
}

interactive_menu() {
    local action
    local answer

    if [[ "$(detected_app_count)" == 0 && ! state_exists ]]; then
        show_detection

        write_domain_state_interactive
        select_apps_interactive

        show_plan "$SELECTED_APPS_RESULT"

        read -r -p \
            "Start the complete installation now using this plan? [Y/n]: " \
            answer

        answer="${answer:-Y}"

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            run_installation "$SELECTED_APPS_RESULT"
        else
            echo "Installation cancelled. Saved settings remain available."
        fi

        return
    fi

    show_detection

    echo
    echo "What would you like to do?"
    echo
    echo "  1) Update the existing installation"
    echo "  2) Modify saved settings and application selection"
    echo "  3) Install an application"
    echo "  4) Create a custom application"
    echo "  5) Update application source only"
    echo "  6) Remove one application"
    echo "  7) Remove the complete managed server package"
    echo "  8) Exit without changes"
    echo

    read -r -p "Choose one action [1-8]: " action

    case "$action" in
        1) update_installed ;;
        2) modify_settings ;;
        3) install_application ;;
        4) create_custom_app ;;
        5) update_source_only ;;
        6) remove_application ;;
        7) remove_server_package ;;
        8) echo "No changes made." ;;
        *) die "Invalid menu selection: $action" ;;
    esac
}

main() {
    local mode="interactive"
    local app_arg=""
    local selected
    local answer

    while (($#)); do
        case "$1" in
            --all)
                mode="all"
                ;;
            --app)
                shift

                [[ $# -gt 0 ]] ||
                    die "--app requires an application name."

                mode="app"
                app_arg="$1"
                ;;
            --reconfigure)
                RECONFIGURE=true
                ;;
            --reconfigure-domain)
                DOMAIN_RECONFIGURE=true
                ;;
            --list)
                mode="list"
                ;;
            --update-source)
                mode="update-source"
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1 (use --help)."
                ;;
        esac

        shift
    done

    log "Fedora Server Home Services Setup"
    log "Repository: $SCRIPT_DIR"

    if [[ "$mode" == "list" ]]; then
        show_detection
        show_apps
        exit 0
    fi

    if [[ "$mode" == "update-source" ]]; then
        update_source_only
        exit 0
    fi

    if [[ "$mode" == "interactive" ]]; then
        interactive_menu
        exit 0
    fi

    write_domain_state_interactive

    if [[ "$mode" == "all" ]]; then
        selected="$(app_ids | paste -sd ' ' -)"
    else
        validate_app_id "$app_arg"
        selected="$app_arg"
    fi

    validate_config
    save_selection "$selected"
    show_plan "$selected"

    read -r -p \
        "Apply this installation/update plan now? [Y/n]: " \
        answer

    answer="${answer:-Y}"

    [[ "$answer" =~ ^[Yy]$ ]] ||
        exit 0

    run_installation "$selected"
}

main "$@"