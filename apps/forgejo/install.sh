#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
validate_config
ensure_dirs
load_app_config "forgejo"

runtime="$(app_runtime_dir forgejo)"
install -d -m 0750 "$runtime" "$runtime/data"
app_prepare_runtime "forgejo"

chown 1000:1000 "$runtime/data"
chmod 0750 "$runtime/data"

env_file="${runtime}/.env"
cat > "$env_file" <<EOF_ENV
FORGEJO_DOMAIN=$(printf '%q' "$FORGEJO_DOMAIN")
FORGEJO_PORT=$(printf '%q' "$FORGEJO_PORT")
EOF_ENV
chmod 600 "$env_file"

if [[ "${RECONFIGURE:-false}" != "true" ]] && app_is_installed forgejo && app_is_running forgejo && app_is_current forgejo; then
    log "${APP_NAME} is already installed and running; skipping container recreation."
else
    log "Starting/updating ${APP_NAME} with Docker Compose."
    app_compose_up forgejo
fi

app_write_state "forgejo"
verify_app forgejo
log "${APP_NAME} installation is complete."