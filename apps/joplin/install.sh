#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
validate_config
ensure_dirs
load_app_config "joplin"

runtime="$(app_runtime_dir joplin)"
install -d -m 0750 "$runtime" "$runtime/postgres-data"
app_prepare_runtime "joplin"

# Migrate existing Joplin PostgreSQL data from the previous repository layout.
legacy_data="${STACK_DIR}/docker/joplin/postgres-data"
if [[ ! -f "${runtime}/postgres-data/PG_VERSION" && -d "$legacy_data" ]]; then
    log "Migrating existing Joplin PostgreSQL data from the previous repository layout."
    cp -a "$legacy_data"/. "$runtime/postgres-data"/
fi

legacy_env="${STATE_DIR}/joplin.env"
if [[ ! -f "${runtime}/.env" && -f "$legacy_env" ]]; then
    # The legacy file already contains the database password. Extract only the
    # values needed by the new Compose project.
    # shellcheck disable=SC1090
    source "$legacy_env"
    [[ -n "${POSTGRES_PASSWORD:-}" ]] || die "Legacy Joplin env is missing POSTGRES_PASSWORD."
fi

env_file="${runtime}/.env"
if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
    [[ -n "${POSTGRES_PASSWORD:-}" ]] || die "${env_file} exists but POSTGRES_PASSWORD is missing."
    log "Existing Joplin PostgreSQL password found; reusing it."
else
    if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
        log "Reusing the existing Joplin PostgreSQL password from the legacy configuration."
    else
        echo
echo "Joplin Server PostgreSQL configuration"
echo
        read -r -p "Do you want to specify your own Joplin PostgreSQL password? [y/N]: " use_custom

        case "${use_custom:-N}" in
            y|Y|yes|YES)
            while true; do
                read -r -s -p "Enter PostgreSQL password: " POSTGRES_PASSWORD
                echo
                read -r -s -p "Confirm PostgreSQL password: " POSTGRES_PASSWORD_CONFIRM
                echo
                [[ -n "$POSTGRES_PASSWORD" ]] || { echo "Password cannot be empty."; continue; }
                [[ "$POSTGRES_PASSWORD" =~ ^[A-Za-z0-9._@%+=:,/-]+$ ]] || {
                    echo "Password contains unsupported characters."
                    echo "Use only letters, numbers and . _ @ % + = : , / -"
                    continue
                }
                [[ "$POSTGRES_PASSWORD" == "$POSTGRES_PASSWORD_CONFIRM" ]] || {
                    echo "Passwords do not match. Please try again."
                    continue
                }
                break
            done
            ;;
        *)
                POSTGRES_PASSWORD="$(openssl rand -hex 32)"
                log "Generated a random Joplin PostgreSQL password."
                ;;
        esac
    fi

    cat > "$env_file" <<EOF_ENV
JOPLIN_DOMAIN=$(printf '%q' "$JOPLIN_DOMAIN")
JOPLIN_PORT=$(printf '%q' "$JOPLIN_PORT")
POSTGRES_PASSWORD=$(printf '%q' "$POSTGRES_PASSWORD")
EOF_ENV
    chmod 600 "$env_file"
    log "Joplin credentials saved to ${env_file}"
fi

if app_is_installed joplin && app_is_running joplin && app_is_current joplin; then
    log "${APP_NAME} is already installed and running; skipping image pull/recreate."
else
    log "Starting ${APP_NAME} with Docker Compose."
    app_compose_up joplin
fi

app_write_state "joplin"

verify_app joplin
log "${APP_NAME} installation is complete."
