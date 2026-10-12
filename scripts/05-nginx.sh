#!/usr/bin/env bash

set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
validate_config
ensure_dirs

[[ -f "$PROXMOX_STATE" ]] ||
    die "Proxmox state missing. Run the Proxmox stage first."

source "$PROXMOX_STATE"

valid_ipv4 "$PROXMOX_IP" ||
    die "Invalid stored Proxmox IP: $PROXMOX_IP"

install -d -m 0755 "$NGINX_RUNTIME_DIR"
install -d -m 0755 /etc/cockpit

load_public_access_state
access_rules=""
ipv6_http_listener=""
ipv6_https_listener=""
if [[ "$DOMAIN_MODE" == "public" ]]; then
    access_rules="$(public_access_nginx_rules)"
    ipv6_http_listener="listen [::]:80;"
    ipv6_https_listener="listen [::]:443 ssl;"
fi

sed \
    -e "s|__FEDORA_DOMAIN__|${FEDORA_DOMAIN}|g" \
    "${REPO_ROOT}/config/cockpit.conf" \
    > /etc/cockpit/cockpit.conf

chmod 0644 /etc/cockpit/cockpit.conf

fedora_cert="$(infra_certificate_path fedora-server FEDORA_DOMAIN)"
fedora_key="$(infra_certificate_key_path fedora-server FEDORA_DOMAIN)"

proxmox_cert="$(infra_certificate_path proxmox PROXMOX_DOMAIN)"
proxmox_key="$(infra_certificate_key_path proxmox PROXMOX_DOMAIN)"

sed \
    -e "s|__FEDORA_DOMAIN__|${FEDORA_DOMAIN}|g" \
    -e "s|__ACCESS_RULES__|${access_rules}|g" \
    -e "s|__IPV6_HTTP_LISTENER__|${ipv6_http_listener}|g" \
    -e "s|__IPV6_HTTPS_LISTENER__|${ipv6_https_listener}|g" \
    -e "s|__FEDORA_PORT__|${FEDORA_PORT}|g" \
    -e "s|__FEDORA_CERTIFICATE__|${fedora_cert}|g" \
    -e "s|__FEDORA_CERTIFICATE_KEY__|${fedora_key}|g" \
    "${REPO_ROOT}/config/fedora-server.nginx.conf" \
    > "${NGINX_RUNTIME_DIR}/fedora-server.conf"

sed \
    -e "s|__PROXMOX_DOMAIN__|${PROXMOX_DOMAIN}|g" \
    -e "s|__ACCESS_RULES__|${access_rules}|g" \
    -e "s|__IPV6_HTTP_LISTENER__|${ipv6_http_listener}|g" \
    -e "s|__IPV6_HTTPS_LISTENER__|${ipv6_https_listener}|g" \
    -e "s|__PROXMOX_IP__|${PROXMOX_IP}|g" \
    -e "s|__PROXMOX_PORT__|${PROXMOX_PORT}|g" \
    -e "s|__PROXMOX_CERTIFICATE__|${proxmox_cert}|g" \
    -e "s|__PROXMOX_CERTIFICATE_KEY__|${proxmox_key}|g" \
    "${REPO_ROOT}/config/proxmox.nginx.conf" \
    > "${NGINX_RUNTIME_DIR}/proxmox.conf"

if command -v getsebool >/dev/null 2>&1 &&
   command -v setsebool >/dev/null 2>&1; then

    if getsebool httpd_can_network_connect 2>/dev/null |
        grep -q -- ' --> off$'; then

        setsebool -P httpd_can_network_connect 1
    fi
fi

selection_file="${STATE_DIR}/selected-apps.env"
selected_apps=""

if [[ -f "$selection_file" ]]; then
    source "$selection_file"
    selected_apps="${SELECTED_APPS:-}"
fi

for app_id in $(app_ids); do
    should_configure=false

    if [[ " ${selected_apps} " == *" ${app_id} "* ]] ||
       app_is_installed "$app_id"; then
        should_configure=true
    fi

    [[ "$should_configure" == true ]] || continue

    load_app_config "$app_id" || continue

    [[ "${APP_NGINX_ENABLED:-true}" == "true" ]] || continue

    app_nginx_install "$app_id"
done

managed_nginx_state="${STATE_DIR}/managed-nginx-apps"
current_managed=()

for app_id in $(app_ids); do
    should_configure=false

    if [[ " ${selected_apps} " == *" ${app_id} "* ]] ||
       app_is_installed "$app_id"; then
        should_configure=true
    fi

    [[ "$should_configure" == true ]] || continue

    load_app_config "$app_id" || continue

    if [[ "${APP_NGINX_ENABLED:-true}" == "true" ]]; then
        current_managed+=("$app_id")
    fi
done

if [[ -f "$managed_nginx_state" ]]; then
    while IFS= read -r old_app; do
        [[ -n "$old_app" ]] || continue

        if [[ ! " ${current_managed[*]} " == *" ${old_app} "* ]]; then
            rm -f "${NGINX_RUNTIME_DIR}/${old_app}.conf"
        fi
    done < "$managed_nginx_state"
fi

printf '%s\n' "${current_managed[@]}" > "$managed_nginx_state"
chmod 600 "$managed_nginx_state"

nginx -t

if systemctl is-active --quiet cockpit.service; then
    systemctl restart cockpit.service
fi

if systemctl is-active --quiet nginx; then
    systemctl reload nginx
else
    systemctl enable --now nginx
fi

needs_certbot=false

while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue

    load_app_config "$app_id" || continue

    [[ "${APP_CERTIFICATE_ENABLED:-true}" == "true" ]] || continue

    tls_mode="${APP_TLS_MODE:-}"

    if [[ -z "$tls_mode" ]]; then
        if [[ "$DOMAIN_MODE" == "public" ]]; then
            tls_mode="acme"
        else
            tls_mode="local-ca"
        fi
    fi

    [[ "$tls_mode" == "acme" ]] || continue

    if [[ "$DOMAIN_MODE" == "public" ||
          "${APP_TYPE:-}" == "custom" ]]; then
        needs_certbot=true
        break
    fi
done < <(certificate_app_ids)

if [[ "$needs_certbot" == true ]]; then
    cat > /etc/systemd/system/fedora-server-certbot-renew.service <<'EOF_SERVICE'
[Unit]
Description=Renew Fedora Server ACME certificates
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/fedora-server-setup/certbot-venv/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF_SERVICE

    cat > /etc/systemd/system/fedora-server-certbot-renew.timer <<'EOF_TIMER'
[Unit]
Description=Twice-daily Fedora Server ACME renewal check

[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER

    systemctl daemon-reload
    systemctl enable --now fedora-server-certbot-renew.timer
else
    systemctl disable --now fedora-server-certbot-renew.timer 2>/dev/null || true
    rm -f \
        /etc/systemd/system/fedora-server-certbot-renew.service \
        /etc/systemd/system/fedora-server-certbot-renew.timer
    systemctl daemon-reload
fi

sync_public_ddns_state
load_godaddy_ddns_state

if [[ "$GODADDY_DDNS_ENABLED" == "true" && "$DOMAIN_MODE" == "public" && -s "$GODADDY_CREDENTIALS" ]] &&
   find "$PUBLIC_DDNS_DIR" -maxdepth 1 -type f -name '*.conf' -print -quit | grep -q .; then
    install -m 0750 "${REPO_ROOT}/scripts/ddns-update.sh" "${STACK_DIR}/ddns-update.sh"
    cat > /etc/systemd/system/fedora-server-ddns.service <<EOF_DDNS_SERVICE
[Unit]
Description=Update public application DNS records through GoDaddy
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${STACK_DIR}/ddns-update.sh
EOF_DDNS_SERVICE
    cat > /etc/systemd/system/fedora-server-ddns.timer <<'EOF_DDNS_TIMER'
[Unit]
Description=Refresh public application DNS records every five minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF_DDNS_TIMER
    systemctl daemon-reload
    systemctl enable --now fedora-server-ddns.timer
    systemctl start fedora-server-ddns.service || warn "Initial DDNS update failed; the timer will retry."
else
    systemctl disable --now fedora-server-ddns.timer 2>/dev/null || true
    systemctl stop fedora-server-ddns.service 2>/dev/null || true
    rm -f /etc/systemd/system/fedora-server-ddns.service /etc/systemd/system/fedora-server-ddns.timer "${STACK_DIR}/ddns-update.sh"
    systemctl daemon-reload
fi

log "Nginx reverse proxy is ready."