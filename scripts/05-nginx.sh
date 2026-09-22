#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
validate_config
ensure_dirs

install -d -m 0755 "$NGINX_RUNTIME_DIR"

if command -v getsebool >/dev/null 2>&1 && command -v setsebool >/dev/null 2>&1; then
    if getsebool httpd_can_network_connect 2>/dev/null | grep -q -- ' --> off$'; then
        log "Enabling SELinux httpd_can_network_connect for Nginx reverse proxy."
        setsebool -P httpd_can_network_connect 1
    fi
fi

# Install/update configs for every selected or already-installed application.
selection_file="${STATE_DIR}/selected-apps.env"
selected_apps=""
if [[ -f "$selection_file" ]]; then
    # shellcheck disable=SC1090
    source "$selection_file"
    selected_apps="${SELECTED_APPS:-}"
fi

for app_id in $(app_ids); do
    should_configure=false
    if [[ " ${selected_apps} " == *" ${app_id} "* ]] || app_is_installed "$app_id"; then
        should_configure=true
    fi
    [[ "$should_configure" == true ]] || continue

    load_app_config "$app_id" || continue
    [[ "${APP_NGINX_ENABLED:-true}" == "true" ]] || continue
    app_nginx_install "$app_id"
done

nginx -t

if systemctl is-active --quiet nginx; then
    log "Nginx is already running; reloading configuration."
    systemctl reload nginx
else
    systemctl enable --now nginx
fi

log "Nginx reverse proxy is ready."
