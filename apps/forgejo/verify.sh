#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
load_app_config "forgejo"

app_is_running forgejo || die "${APP_NAME} container is not running."

curl -fsS --max-time 15 "http://127.0.0.1:${FORGEJO_PORT}/" >/dev/null || die "${APP_NAME} local health check failed."

log "${APP_NAME} health check passed."