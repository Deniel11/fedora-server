#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
validate_config
ensure_dirs
load_app_config "vaultwarden"

runtime="$(app_runtime_dir vaultwarden)"
install -d -m 0750 "$runtime" "$runtime/data"
app_prepare_runtime "vaultwarden"

# Migrate data from the previous repository layout without deleting the old copy.
legacy_data="${STACK_DIR}/docker/vaultwarden/data"
if [[ ! -f "${runtime}/data/db.sqlite3" && -d "$legacy_data" ]]; then
    log "Migrating existing Vaultwarden data from the previous repository layout."
    cp -a "$legacy_data"/. "$runtime/data"/
fi

cat > "${runtime}/.env" <<EOF_ENV
VAULTWARDEN_DOMAIN=${VAULTWARDEN_DOMAIN}
VAULTWARDEN_PORT=${VAULTWARDEN_PORT}
VAULTWARDEN_NOTIFICATIONS_HUB_PORT=${VAULTWARDEN_NOTIFICATIONS_HUB_PORT}
EOF_ENV
chmod 600 "${runtime}/.env"

if app_is_installed vaultwarden && app_is_running vaultwarden && app_is_current vaultwarden; then
    log "${APP_NAME} is already installed and running; skipping container recreation."
else
    log "Starting ${APP_NAME} with Docker Compose."
    app_compose_up vaultwarden
fi

app_write_state "vaultwarden"

verify_app vaultwarden
log "${APP_NAME} installation is complete."
