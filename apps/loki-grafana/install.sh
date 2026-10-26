#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
validate_config
ensure_dirs
load_app_config "loki-grafana"

retention="${LOKI_RETENTION_PERIOD:-30d}"
[[ "$retention" =~ ^[1-9][0-9]*(h|d|w|y)$ ]] ||
    die "Invalid LOKI_RETENTION_PERIOD=${retention}. Use a positive duration such as 24h, 30d, 8w or 1y."

runtime="$(app_runtime_dir loki-grafana)"
data_dir="${APP_DATA_DIR}"
env_file="${data_dir}/.env"

install -d -m 0750 "$runtime" "$data_dir" "${data_dir}/loki" "${data_dir}/grafana" "${data_dir}/alloy"
app_prepare_runtime "loki-grafana"

install -m 0644 "$(app_dir loki-grafana)/loki-config.yml" "${runtime}/loki-config.yml"
install -m 0644 "$(app_dir loki-grafana)/config.alloy" "${runtime}/config.alloy"
install -d -m 0750 "${runtime}/provisioning/datasources"
install -m 0644 "$(app_dir loki-grafana)/provisioning/datasources/loki.yml" "${runtime}/provisioning/datasources/loki.yml"
install -d -m 0750 "${runtime}/provisioning/dashboards"
install -m 0644 "$(app_dir loki-grafana)/provisioning/dashboards/provider.yml" "${runtime}/provisioning/dashboards/provider.yml"
install -m 0644 "$(app_dir loki-grafana)/provisioning/dashboards/nginx-analytics.json" "${runtime}/provisioning/dashboards/nginx-analytics.json"
install -m 0644 "$(app_dir loki-grafana)/provisioning/dashboards/nginx-visitor-analytics.json" "${runtime}/provisioning/dashboards/nginx-visitor-analytics.json"

if [[ -f "$env_file" ]]; then
    source "$env_file"
    [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] ||
        die "Existing ${env_file} does not contain GRAFANA_ADMIN_PASSWORD."
    log "Reusing the existing Grafana admin password."
else
    GRAFANA_ADMIN_PASSWORD="$(openssl rand -hex 32)"
fi

cat > "$env_file" <<EOF_ENV
GRAFANA_DOMAIN=${APP_DOMAIN}
GRAFANA_PORT=${APP_PORT}
LOKI_PORT=${LOKI_PORT}
LOKI_RETENTION_PERIOD=${retention}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
LOKI_DATA_DIR=${data_dir}/loki
GRAFANA_DATA_DIR=${data_dir}/grafana
ALLOY_DATA_DIR=${data_dir}/alloy
EOF_ENV
chmod 600 "$env_file"
ln -sfn "$env_file" "${runtime}/.env"

chown 10001:10001 "${data_dir}/loki"
chown 472:472 "${data_dir}/grafana"
chmod 0750 "${data_dir}/loki" "${data_dir}/grafana" "${data_dir}/alloy"

if [[ "${RECONFIGURE:-false}" != "true" ]] && app_is_installed loki-grafana && app_is_running loki-grafana && app_is_current loki-grafana; then
    log "${APP_NAME} is already installed and running; checking service health."
else
    log "Starting/updating ${APP_NAME} with Docker Compose."
    app_compose_up loki-grafana
fi

app_write_state "loki-grafana"
verify_app loki-grafana
log "${APP_NAME} installation is complete."
