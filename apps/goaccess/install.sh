#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
validate_config
ensure_dirs
load_app_config "goaccess"

runtime="$(app_runtime_dir goaccess)"
install -d -m 0750 "$runtime"
app_prepare_runtime "goaccess"
install -m 0644 "$(app_dir goaccess)/nginx.internal.conf" "${runtime}/nginx.internal.conf"
install -m 0750 "$(app_dir goaccess)/run-goaccess.sh" "${runtime}/run-goaccess.sh"

env_file="${runtime}/.env"
cat > "$env_file" <<EOF_ENV
GOACCESS_DOMAIN=$(printf '%q' "$APP_DOMAIN")
APP_DOMAIN=$(printf '%q' "$APP_DOMAIN")
GOACCESS_PORT=$(printf '%q' "$APP_PORT")
EOF_ENV
chmod 600 "$env_file"

if [[ ! -r /var/log/nginx/access.log ]]; then
    warn "The Nginx access log is not readable yet; the GoAccess service will wait for it."
fi

if [[ "${RECONFIGURE:-false}" != "true" ]] && app_is_installed goaccess && app_is_running goaccess && app_is_current goaccess; then
    log "${APP_NAME} is already installed and running; skipping container recreation."
else
    log "Starting/updating ${APP_NAME} with Docker Compose."
    app_compose_up goaccess
fi

cat > /etc/systemd/system/fedora-server-goaccess.service <<EOF_SERVICE
[Unit]
Description=GoAccess real-time Nginx log analyzer
After=docker.service nginx.service
Requires=docker.service

[Service]
Type=simple
ExecStart=${runtime}/run-goaccess.sh
Restart=always
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable fedora-server-goaccess.service
systemctl restart fedora-server-goaccess.service

app_write_state "goaccess"
verify_app goaccess
log "${APP_NAME} installation is complete."
