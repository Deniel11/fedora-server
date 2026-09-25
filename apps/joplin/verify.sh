#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_app_config "joplin"

app_is_running joplin || die "${APP_NAME} container is not running."
curl -fsS --max-time 15 http://${JOPLIN_DOMAIN}/api/ping >/dev/null || die "${APP_NAME} HTTPS health check failed."

docker inspect -f '{{.State.Health.Status}}' joplin-postgres 2>/dev/null | grep -qx healthy ||
    die "Joplin PostgreSQL container is not healthy."

log "${APP_NAME} health check passed."
