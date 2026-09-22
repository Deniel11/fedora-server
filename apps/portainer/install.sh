#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
validate_config
ensure_dirs
load_app_config "portainer"

app_prepare_runtime "portainer"

runtime="$(app_runtime_dir portainer)"
cat > "${runtime}/.env" <<EOF_ENV
PORTAINER_PORT=${PORTAINER_PORT}
EOF_ENV
chmod 600 "${runtime}/.env"

if app_is_installed portainer && app_is_running portainer && app_is_current portainer; then
    log "${APP_NAME} is already installed and running; skipping container recreation."
else
    log "Starting ${APP_NAME} with Docker Compose."
    app_compose_up portainer
fi

# Marker means the application was configured by this installer.
app_write_state "portainer"

verify_app portainer
log "${APP_NAME} installation is complete."
