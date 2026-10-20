#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
load_app_config "goaccess"

app_is_running goaccess || die "${APP_NAME} web container is not running."
systemctl is-active --quiet fedora-server-goaccess.service || die "${APP_NAME} log processor service is not active."

for attempt in $(seq 1 30); do
    if docker exec goaccess-processor test -s /report/index.html 2>/dev/null; then
        log "${APP_NAME} report exists and the log processor is running."
        exit 0
    fi
    sleep 1
done

die "${APP_NAME} report was not generated. Check journalctl -u fedora-server-goaccess.service."
