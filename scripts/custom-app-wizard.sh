#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
ensure_dirs

WORK_DIR="${RUNTIME_APP_DIR}/.custom-app-wizard"
mkdir -p "$WORK_DIR"

wizard_die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

valid_app_id_input() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]]
}

valid_ref_input() {
    [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]]
}

normalize_repo_url() {
    local url="$1"
    url="${url%/}"
    url="${url%.git}"
    printf '%s\n' "$url"
}

repo_components() {
    local url="$1"
    local path

    path="${url#*://}"
    path="${path%%\?*}"
    path="${path%%\#*}"
    path="${path#*/}"

    [[ "$path" == */* ]] || return 1

    printf '%s\n' "$path"
}

archive_url_for() {
    local repo_url="$1"
    local ref="$2"

    printf '%s/archive/%s.tar.gz\n' "$(normalize_repo_url "$repo_url")" "$ref"
}

download_source() {
    local archive_url="$1"
    local target="$2"

    rm -rf "$target"
    mkdir -p "$target"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 2 \
        --connect-timeout 15 \
        --max-time 300 \
        "$archive_url" \
        -o "${target}.tar.gz" ||
        return 1

    tar -xzf "${target}.tar.gz" -C "$target" || return 1

    rm -f "${target}.tar.gz"

    local entries=()
    while IFS= read -r entry; do
        entries+=("$entry")
    done < <(find "$target" -mindepth 1 -maxdepth 1 -type d -print)

    if ((${#entries[@]} == 1)); then
        local root="${entries[0]}"
        local tmp="${target}.flattened"
        rm -rf "$tmp"
        mkdir -p "$tmp"
        cp -a "${root}/." "$tmp/"
        rm -rf "$target"
        mv "$tmp" "$target"
    fi
}

source_has_compose() {
    local source="$1"

    for file in \
        compose.yml \
        compose.yaml \
        docker-compose.yml \
        docker-compose.yaml; do
        [[ -f "${source}/${file}" ]] && {
            printf '%s\n' "$file"
            return 0
        }
    done

    return 1
}

source_has_dockerfile() {
    local source="$1"

    [[ -f "${source}/Dockerfile" ]]
}

source_is_buildable() {
    local source="$1"

    for file in \
        package.json \
        requirements.txt \
        pyproject.toml \
        go.mod \
        Cargo.toml \
        pom.xml \
        build.gradle \
        build.gradle.kts \
        Makefile; do
        [[ -f "${source}/${file}" ]] && return 0
    done

    find "$source" -maxdepth 2 -type f \
        \( -name '*.csproj' -o -name '*.fsproj' \) \
        -print -quit |
        grep -q .
}

source_is_static() {
    local source="$1"

    [[ -f "${source}/index.html" ]]
}

choose_deployment() {
    local source="$1"
    local compose_file=""
    local has_dockerfile=false
    local buildable=false
    local static=false
    local choice

    compose_file="$(source_has_compose "$source" || true)"
    source_has_dockerfile "$source" && has_dockerfile=true
    source_is_buildable "$source" && buildable=true
    source_is_static "$source" && static=true

    echo
    echo "Source inspection:"
    echo "  Compose file : ${compose_file:-not found}"
    echo "  Dockerfile   : ${has_dockerfile}"
    echo "  Buildable    : ${buildable}"
    echo "  Static       : ${static}"
    echo

    if [[ -n "$compose_file" && "$has_dockerfile" == true ]]; then
        echo "Both a Compose file and a Dockerfile were found."
        echo "Compose is recommended because it preserves the repository's service layout."
        echo
        echo "  1) Compose"
        echo "  2) Dockerfile"
        echo
        read -r -p "Choose deployment type [1-2]: " choice

        case "$choice" in
            1)
                APP_DEPLOY_TYPE="compose"
                APP_SOURCE_COMPOSE="$compose_file"
                ;;
            2)
                APP_DEPLOY_TYPE="dockerfile"
                APP_SOURCE_COMPOSE=""
                ;;
            *)
                wizard_die "Invalid deployment selection."
                ;;
        esac

        return
    fi

    if [[ -n "$compose_file" ]]; then
        APP_DEPLOY_TYPE="compose"
        APP_SOURCE_COMPOSE="$compose_file"
        return
    fi

    if [[ "$has_dockerfile" == true ]]; then
        APP_DEPLOY_TYPE="dockerfile"
        APP_SOURCE_COMPOSE=""
        return
    fi

    if [[ "$buildable" == true ]]; then
        echo "The source appears to be buildable, but no Dockerfile was found."
        echo "A Dockerfile is required for Dockerfile deployment."
        echo
        echo "The installer will not generate or modify a Dockerfile."
        echo
        echo "Create it manually on Linux, for example:"
        echo "mkdir -p ${source}/"
        echo "cat > ${source}/Dockerfile <<'EOF'"
        echo "FROM ..."
        echo "..."
        echo "EOF"
        echo
        echo "After creating the Dockerfile, run the custom application wizard again."
        exit 2
    fi

    if [[ "$static" == true ]]; then
        APP_DEPLOY_TYPE="static"
        APP_SOURCE_COMPOSE=""
        return
    fi

    echo "No supported deployment layout was detected."
    echo "The source needs a Compose file, a Dockerfile, or a static index.html."
    exit 2
}

choose_compose_settings() {
    local source="$1"
    local service
    local port

    echo
    echo "Detected Compose services:"
    awk '
        /^services:/ { in_services=1; next }
        in_services && /^  [A-Za-z0-9_.-]+:/ {
            name=$1
            sub(/:$/, "", name)
            print name
        }
    ' "${source}/${APP_SOURCE_COMPOSE}" || true

    echo

    read -r -p "Web-facing Compose service name: " service
    [[ -n "$service" ]] || wizard_die "Compose service name cannot be empty."

    read -r -p "Container port exposed by the web service [80]: " port
    port="${port:-80}"

    valid_port "$port" ||
        wizard_die "Invalid container port."

    APP_SOURCE_SERVICE="$service"
    APP_SOURCE_CONTAINER_PORT="$port"
}

choose_dockerfile_settings() {
    local port

    read -r -p "Container port exposed by the Dockerfile [80]: " port
    port="${port:-80}"

    valid_port "$port" ||
        wizard_die "Invalid container port."

    APP_SOURCE_SERVICE="app"
    APP_SOURCE_CONTAINER_PORT="$port"
}

choose_static_settings() {
    local root

    read -r -p "Static document root relative to repository [/]: " root
    root="${root:-/}"

    root="${root#/}"
    root="${root%/}"

    APP_SOURCE_ROOT="$root"
}

choose_tls() {
    local choice

    echo
    echo "TLS mode:"
    echo "  1) Let's Encrypt ACME"
    echo "  2) Local CA"
    echo "  3) HTTP only"
    echo

    read -r -p "Choose TLS mode [1-3]: " choice

    case "$choice" in
        1)
            APP_TLS_MODE="acme"
            ;;
        2)
            APP_TLS_MODE="local-ca"
            ;;
        3)
            APP_TLS_MODE="none"
            ;;
        *)
            wizard_die "Invalid TLS selection."
            ;;
    esac
}

choose_domain() {
    local domain
    local aliases

    echo
    read -r -p "Primary application domain: " domain

    valid_hostname "$domain" ||
        wizard_die "Invalid application domain."

    read -r -p "Additional aliases separated by spaces, or leave empty: " aliases

    for alias in $aliases; do
        valid_hostname "$alias" ||
            wizard_die "Invalid alias: $alias"
    done

    APP_DOMAIN="$domain"
    APP_CANONICAL_DOMAIN="$domain"
    APP_DOMAIN_ALIASES="$aliases"
}

choose_ports() {
    local port

    if [[ "$APP_DEPLOY_TYPE" == "static" ]]; then
        APP_PORT="1"
        return
    fi

    read -r -p "Host port for the application backend: " port

    valid_port "$port" ||
        wizard_die "Invalid host port."

    APP_PORT="$port"
}

write_nginx_config() {
    local dir="$1"
    local aliases="$APP_DOMAIN_ALIASES"
    local alias_server=""
    local redirect_scheme="https"

    if [[ "$APP_TLS_MODE" == "none" ]]; then
        redirect_scheme="http"
    fi

    if [[ -n "$aliases" ]]; then
        alias_server="
server {
    listen 80;
    server_name ${aliases};
    return 301 ${redirect_scheme}://${APP_CANONICAL_DOMAIN}\$request_uri;
}
"

        if [[ "$APP_TLS_MODE" != "none" ]]; then
            alias_server="${alias_server}
server {
    listen 443 ssl;
    server_name ${aliases};
    ssl_certificate __APP_CERTIFICATE__;
    ssl_certificate_key __APP_CERTIFICATE_KEY__;
    return 301 https://${APP_CANONICAL_DOMAIN}\$request_uri;
}
"
        fi
    fi

    if [[ "$APP_TLS_MODE" == "none" ]]; then
        cat > "${dir}/nginx.conf" <<EOF_NGINX
server {
    listen 80;
    server_name __APP_DOMAIN__;
    location / {
$(if [[ "$APP_DEPLOY_TYPE" == "static" ]]; then
printf '        root __APP_SOURCE_ROOT__;\n        try_files \$uri \$uri/ /index.html;\n'
else
printf '        proxy_pass http://127.0.0.1:__APP_PORT__;\n        proxy_set_header Host \$host;\n        proxy_set_header X-Real-IP \$remote_addr;\n        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto \$scheme;\n'
fi)
    }
}
${alias_server}
EOF_NGINX
        return
    fi

    cat > "${dir}/nginx.conf" <<EOF_NGINX
server {
    listen 80;
    server_name __APP_DOMAIN__;
    return 301 https://__APP_CANONICAL_DOMAIN__\$request_uri;
}

server {
    listen 443 ssl;
    server_name __APP_DOMAIN__;
    ssl_certificate __APP_CERTIFICATE__;
    ssl_certificate_key __APP_CERTIFICATE_KEY__;
    location / {
$(if [[ "$APP_DEPLOY_TYPE" == "static" ]]; then
printf '        root __APP_SOURCE_ROOT__;\n        try_files \$uri \$uri/ /index.html;\n'
else
printf '        proxy_pass http://127.0.0.1:__APP_PORT__;\n        proxy_set_header Host \$host;\n        proxy_set_header X-Real-IP \$remote_addr;\n        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto \$scheme;\n'
fi)
    }
}
${alias_server}
EOF_NGINX
}

write_app_config() {
    local dir="$1"

    cat > "${dir}/app.conf" <<EOF_CONF
APP_ID=$(printf '%q' "$APP_ID")
APP_NAME=$(printf '%q' "$APP_NAME")
APP_TYPE="custom"
APP_ENABLED="true"
APP_SOURCE_TYPE="forgejo"
APP_SOURCE_URL=$(printf '%q' "$APP_SOURCE_URL")
APP_SOURCE_REF=$(printf '%q' "$APP_SOURCE_REF")
APP_DEPLOY_TYPE=$(printf '%q' "$APP_DEPLOY_TYPE")
APP_SOURCE_COMPOSE=$(printf '%q' "${APP_SOURCE_COMPOSE:-}")
APP_SOURCE_SERVICE=$(printf '%q' "${APP_SOURCE_SERVICE:-}")
APP_SOURCE_CONTAINER_PORT=$(printf '%q' "${APP_SOURCE_CONTAINER_PORT:-}")
APP_SOURCE_ROOT=$(printf '%q' "${APP_SOURCE_ROOT:-}")
APP_DOMAIN=$(printf '%q' "$APP_DOMAIN")
APP_CANONICAL_DOMAIN=$(printf '%q' "$APP_CANONICAL_DOMAIN")
APP_DOMAIN_ALIASES=$(printf '%q' "$APP_DOMAIN_ALIASES")
APP_TLS_MODE=$(printf '%q' "$APP_TLS_MODE")
APP_PORT=$(printf '%q' "$APP_PORT")
APP_CONTAINER=$(printf '%q' "$APP_ID")
APP_TLS_NAME=$(printf '%q' "$APP_ID")
APP_NGINX_ENABLED="true"
APP_CERTIFICATE_ENABLED=$([[ "$APP_TLS_MODE" == "none" ]] && printf 'false' || printf 'true')
APP_HEALTHCHECK_URL=$(printf '%q' "$([[ "$APP_TLS_MODE" == "none" ]] && printf 'http' || printf 'https')://127.0.0.1:${APP_PORT}/")
EOF_CONF
}

write_install_script() {
    local dir="$1"

    cat > "${dir}/install.sh" <<'EOF_INSTALL'
#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
ensure_dirs
load_app_config "$APP_ID"

runtime="$(app_runtime_dir "$APP_ID")"
source_dir="${runtime}/source"
pending_dir="${runtime}/source-pending"

install -d -m 0750 "$runtime"

if [[ -d "$pending_dir" ]]; then
    rm -rf "$source_dir"
    mv "$pending_dir" "$source_dir"
fi

[[ -d "$source_dir" ]] || die "No application source is available for ${APP_ID}."

case "$APP_DEPLOY_TYPE" in
    static)
        rm -f "${runtime}/compose.yml" "${runtime}/compose.override.yml"
        install -d -m 0755 "${runtime}/public"
        rm -rf "${runtime}/public"/*
        cp -a "${source_dir}/." "${runtime}/public/"
        ;;
    compose)
        [[ -f "${source_dir}/${APP_SOURCE_COMPOSE}" ]] ||
            die "Compose file is missing: ${APP_SOURCE_COMPOSE}"

        cp "${source_dir}/${APP_SOURCE_COMPOSE}" "${runtime}/compose.yml"

        cat > "${runtime}/compose.override.yml" <<EOF_OVERRIDE
services:
  ${APP_SOURCE_SERVICE}:
    ports: !override
      - "127.0.0.1:${APP_PORT}:${APP_SOURCE_CONTAINER_PORT}"
EOF_OVERRIDE

        (
            cd "$runtime"
            docker compose \
                -f compose.yml \
                -f compose.override.yml \
                up -d
        )
        ;;
    dockerfile)
        [[ -f "${source_dir}/Dockerfile" ]] ||
            die "Dockerfile is required but was not found."

        cat > "${runtime}/compose.yml" <<EOF_COMPOSE
services:
  ${APP_CONTAINER}:
    build:
      context: ./source
      dockerfile: Dockerfile
    ports:
      - "127.0.0.1:${APP_PORT}:${APP_SOURCE_CONTAINER_PORT}"
    restart: unless-stopped
EOF_COMPOSE

        (
            cd "$runtime"
            docker compose -f compose.yml up -d --build
        )
        ;;
    *)
        die "Unsupported deployment type: ${APP_DEPLOY_TYPE}"
        ;;
esac

app_write_state "$APP_ID"

log "Custom application ${APP_NAME} is deployed."
EOF_INSTALL

    chmod 0755 "${dir}/install.sh"
}

write_verify_script() {
    local dir="$1"

    cat > "${dir}/verify.sh" <<'EOF_VERIFY'
#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
load_app_config "$APP_ID"

runtime="$(app_runtime_dir "$APP_ID")"

[[ -f "${runtime}/.installed" ]] ||
    die "Application ${APP_ID} is not marked as installed."

case "$APP_DEPLOY_TYPE" in
    static)
        [[ -f "${runtime}/public/index.html" ]] ||
            die "Static application content is missing."
        ;;
    compose|dockerfile)
        app_is_running "$APP_ID" ||
            die "Application container is not running."
        ;;
    *)
        die "Unsupported deployment type: ${APP_DEPLOY_TYPE}"
        ;;
esac

log "Application ${APP_NAME} verification passed."
EOF_VERIFY

    chmod 0755 "${dir}/verify.sh"
}

write_remove_script() {
    local dir="$1"

    cat > "${dir}/remove.sh" <<'EOF_REMOVE'
#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
load_app_config "$APP_ID"

runtime="$(app_runtime_dir "$APP_ID")"

if [[ "$APP_DEPLOY_TYPE" == "compose" || "$APP_DEPLOY_TYPE" == "dockerfile" ]]; then
    if [[ -f "${runtime}/compose.yml" ]]; then
        (
            cd "$runtime"
            docker compose -f compose.yml down --remove-orphans
        )
    fi
fi

rm -rf "$runtime"
app_nginx_remove "$APP_ID"
EOF_REMOVE

    chmod 0755 "${dir}/remove.sh"
}

app_id_exists() {
    local id="$1"
    [[ -d "$(app_dir "$id")" ]]
}

choose_app_id() {
    local id

    read -r -p "Application ID: " id
    id="${id,,}"

    valid_app_id_input "$id" ||
        wizard_die "Application ID must contain lowercase letters, numbers, and hyphens."

    app_id_exists "$id" &&
        wizard_die "Application ID already exists: $id"

    APP_ID="$id"
}

choose_app_name() {
    local name

    read -r -p "Application display name: " name

    [[ -n "$name" ]] ||
        wizard_die "Application name cannot be empty."

    APP_NAME="$name"
}

choose_repository() {
    local url
    local ref
    local archive

    read -r -p "Forgejo repository URL: " url
    url="$(normalize_repo_url "$url")"

    repo_components "$url" >/dev/null ||
        wizard_die "Repository URL must point to a Forgejo repository in /owner/repository form."

    read -r -p "Branch or ref [main]: " ref
    ref="${ref:-main}"

    valid_ref_input "$ref" ||
        wizard_die "Invalid branch or ref."

    archive="$(archive_url_for "$url" "$ref")"

    echo
    echo "Checking repository archive access with curl:"
    echo "$archive"
    echo

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --range 0-0 \
        "$archive" \
        -o /dev/null ||
        wizard_die "The Forgejo repository archive is not accessible. Check the repository URL and ref."

    APP_SOURCE_URL="$url"
    APP_SOURCE_REF="$ref"
}

main() {
    local source_target
    local app_dir_path
    local archive
    local answer

    echo
    echo "========================================"
    echo " Custom application wizard"
    echo "========================================"
    echo
    echo "This wizard creates the application definition and deployment files."
    echo "It never creates or modifies a Dockerfile."
    echo

    choose_app_id
    choose_app_name
    choose_repository

    source_target="${WORK_DIR}/${APP_ID}"
    archive="$(archive_url_for "$APP_SOURCE_URL" "$APP_SOURCE_REF")"

    echo
    echo "Downloading source with curl..."
    download_source "$archive" "$source_target" ||
        wizard_die "Source download failed."

    choose_deployment "$source_target"

    case "$APP_DEPLOY_TYPE" in
        compose)
            choose_compose_settings "$source_target"
            ;;
        dockerfile)
            choose_dockerfile_settings
            ;;
        static)
            choose_static_settings
            ;;
    esac

    choose_domain
    choose_tls
    choose_ports

    app_dir_path="$(app_dir "$APP_ID")"

    install -d -m 0755 "$app_dir_path"

    write_app_config "$app_dir_path"
    write_install_script "$app_dir_path"
    write_verify_script "$app_dir_path"
    write_remove_script "$app_dir_path"
    write_nginx_config "$app_dir_path"

    runtime="$(app_runtime_dir "$APP_ID")"
    install -d -m 0750 "$runtime"
    rm -rf "${runtime}/source-pending"
    cp -a "${source_target}/." "${runtime}/source-pending/"

    printf '%s\n' "$APP_SOURCE_REF" > "${runtime}/pending-ref"

    echo
    echo "Custom application created:"
    echo "  ID           : ${APP_ID}"
    echo "  Name         : ${APP_NAME}"
    echo "  Repository   : ${APP_SOURCE_URL}"
    echo "  Ref          : ${APP_SOURCE_REF}"
    echo "  Deployment   : ${APP_DEPLOY_TYPE}"
    echo "  Domain       : ${APP_DOMAIN}"
    echo "  TLS          : ${APP_TLS_MODE}"

    if [[ "$APP_DEPLOY_TYPE" == "dockerfile" ]]; then
        echo
        echo "Dockerfile handling:"
        echo "  The Dockerfile remains entirely under repository control."
        echo "  The wizard does not create or modify it."
    fi

    echo
    read -r -p "Add this application to the managed installation now? [Y/n]: " answer
    answer="${answer:-Y}"

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        printf '%s\n' "$APP_ID"
        exit 0
    fi

    echo "Custom application created but not added to the installation selection."
}

main "$@"