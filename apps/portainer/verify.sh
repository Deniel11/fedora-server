#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_app_config "portainer"
[[ -f "$NETWORK_STATE" ]] || die "Network state is missing."
# shellcheck disable=SC1090
source "$NETWORK_STATE"

app_is_running portainer || die "${APP_NAME} container is not running."
curl -ksS --max-time 10 --resolve "${APP_DOMAIN}:443:${STATIC_IP}" "${APP_HEALTHCHECK_URL}" >/dev/null || die "${APP_NAME} HTTPS health check failed."
log "${APP_NAME} health check passed."
