#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
validate_config

[[ -f "$NETWORK_STATE" ]] || die "Network state not found."
# shellcheck disable=SC1090
source "$NETWORK_STATE"

PROXMOX_IP="not-set"
if [[ -f "$PROXMOX_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$PROXMOX_STATE"
fi

selected_apps=""
if [[ -f "${STATE_DIR}/selected-apps.env" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_DIR}/selected-apps.env"
    selected_apps="${SELECTED_APPS:-}"
fi

echo
echo "========================================"
echo " Verification"
echo "========================================"

FAILURES=0
check() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '[ OK ] %s
' "$label"
    else
        printf '[FAIL] %s
' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

check "Docker service" systemctl is-active --quiet docker
check "Nginx service" systemctl is-active --quiet nginx
check "Nginx configuration" nginx -t

if systemctl is-active --quiet cockpit.socket; then
    printf '[ OK ] Cockpit socket
'
else
    printf '[WARN] Cockpit socket is not active
'
fi

for app_id in $(app_ids); do
    app_is_installed "$app_id" || continue
    load_app_config "$app_id" || continue
    if app_is_running "$app_id"; then
        printf '[ OK ] %s container is running
' "$APP_NAME"
    else
        printf '[FAIL] %s container is not running
' "$APP_NAME"
        FAILURES=$((FAILURES + 1))
    fi

    if [[ " ${selected_apps} " == *" ${app_id} "* ]]; then
        if verify_app "$app_id" >/dev/null 2>&1; then
            printf '[ OK ] %s application health check
' "$APP_NAME"
        else
            printf '[FAIL] %s application health check
' "$APP_NAME"
            FAILURES=$((FAILURES + 1))
        fi
    fi
done

echo
echo "========================================"
echo " Addresses"
echo "========================================"
echo "Proxmox        : https://${PROXMOX_DOMAIN}"
echo "Fedora/Cockpit : https://${FEDORA_DOMAIN}"

for app_id in $(app_ids); do
    app_is_installed "$app_id" || continue
    load_app_config "$app_id" || continue
    printf '%-15s: https://%s
' "${APP_NAME}" "${APP_DOMAIN}"
done

echo
echo "Backend addresses:"
echo "Cockpit        : https://127.0.0.1:${FEDORA_PORT}"
echo "Proxmox backend : https://${PROXMOX_IP}:${PROXMOX_PORT}"

echo
echo "DNS records for OPNsense/AdGuard:"
echo "  ${FEDORA_DOMAIN} -> ${STATIC_IP}"
for app_id in $(app_ids); do
    app_is_installed "$app_id" || continue
    load_app_config "$app_id" || continue
    printf '  %-20s -> %s
' "${APP_DOMAIN}" "${STATIC_IP}"
done
echo "  ${PROXMOX_DOMAIN} -> ${STATIC_IP}"

echo
echo "Local CA:"
echo "  ${TLS_DIR}/ca.crt"
warn "Import ca.crt into client trust stores to remove HTTPS trust warnings."

if (( FAILURES > 0 )); then
    printf '
[ERROR] Verification failed: %d check(s) failed.
' "$FAILURES" >&2
    exit 1
fi

printf '
[ OK ] All critical verification checks passed.
'
