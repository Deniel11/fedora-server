#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
load_app_config "loki-grafana"

app_is_running loki-grafana ||
    die "${APP_NAME} Grafana container is not running."

docker inspect -f '{{.State.Running}}' loki 2>/dev/null |
    grep -qx true ||
    die "Loki container is not running."

docker inspect -f '{{.State.Running}}' grafana-alloy 2>/dev/null |
    grep -qx true ||
    die "Grafana Alloy container is not running."

curl -fsS --max-time 15 "http://127.0.0.1:${LOKI_PORT}/ready" >/dev/null ||
    die "Loki readiness check failed."

curl -fsS --max-time 15 "http://127.0.0.1:${GRAFANA_PORT}/api/health" >/dev/null ||
    die "Grafana health check failed."

log "${APP_NAME} health checks passed."
