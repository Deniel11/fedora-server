#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"
require_root; require_fedora; load_config; load_domain_state; validate_config; ensure_dirs
[[ -f "$PROXMOX_STATE" ]] || die "Proxmox state missing. Run the Proxmox stage first."; source "$PROXMOX_STATE"; valid_ipv4 "$PROXMOX_IP" || die "Invalid stored Proxmox IP: $PROXMOX_IP"
install -d -m 0755 "$NGINX_RUNTIME_DIR"; install -d -m 0755 /etc/cockpit; install -m 0644 "${REPO_ROOT}/config/cockpit.conf" /etc/cockpit/cockpit.conf
fedora_cert="$(infra_certificate_path fedora-server FEDORA_DOMAIN)"; fedora_key="$(infra_certificate_key_path fedora-server FEDORA_DOMAIN)"; proxmox_cert="$(infra_certificate_path proxmox PROXMOX_DOMAIN)"; proxmox_key="$(infra_certificate_key_path proxmox PROXMOX_DOMAIN)"
sed -e "s|__FEDORA_DOMAIN__|${FEDORA_DOMAIN}|g" -e "s|__FEDORA_PORT__|${FEDORA_PORT}|g" -e "s|__FEDORA_CERTIFICATE__|${fedora_cert}|g" -e "s|__FEDORA_CERTIFICATE_KEY__|${fedora_key}|g" "${REPO_ROOT}/config/fedora-server.nginx.conf" > "${NGINX_RUNTIME_DIR}/fedora-server.conf"
sed -e "s|__PROXMOX_DOMAIN__|${PROXMOX_DOMAIN}|g" -e "s|__PROXMOX_IP__|${PROXMOX_IP}|g" -e "s|__PROXMOX_PORT__|${PROXMOX_PORT}|g" -e "s|__PROXMOX_CERTIFICATE__|${proxmox_cert}|g" -e "s|__PROXMOX_CERTIFICATE_KEY__|${proxmox_key}|g" "${REPO_ROOT}/config/proxmox.nginx.conf" > "${NGINX_RUNTIME_DIR}/proxmox.conf"
if command -v getsebool >/dev/null 2>&1 && command -v setsebool >/dev/null 2>&1; then if getsebool httpd_can_network_connect 2>/dev/null | grep -q -- ' --> off$'; then setsebool -P httpd_can_network_connect 1; fi; fi
selection_file="${STATE_DIR}/selected-apps.env"; selected_apps=""; if [[ -f "$selection_file" ]]; then source "$selection_file"; selected_apps="${SELECTED_APPS:-}"; fi
for app_id in $(app_ids); do should_configure=false; if [[ " ${selected_apps} " == *" ${app_id} "* ]] || app_is_installed "$app_id"; then should_configure=true; fi; [[ "$should_configure" == true ]] || continue; load_app_config "$app_id" || continue; [[ "${APP_NGINX_ENABLED:-true}" == "true" ]] || continue; app_nginx_install "$app_id"; done
managed_nginx_state="${STATE_DIR}/managed-nginx-apps"; current_managed=(); for app_id in $(app_ids); do should_configure=false; if [[ " ${selected_apps} " == *" ${app_id} "* ]] || app_is_installed "$app_id"; then should_configure=true; fi; [[ "$should_configure" == true ]] || continue; load_app_config "$app_id" || continue; [[ "${APP_NGINX_ENABLED:-true}" == "true" ]] && current_managed+=("$app_id"); done
if [[ -f "$managed_nginx_state" ]]; then while IFS= read -r old_app; do [[ -n "$old_app" ]] || continue; if [[ ! " ${current_managed[*]} " == *" ${old_app} "* ]]; then rm -f "${NGINX_RUNTIME_DIR}/${old_app}.conf"; fi; done < "$managed_nginx_state"; fi
printf '%s\n' "${current_managed[@]}" > "$managed_nginx_state"; chmod 600 "$managed_nginx_state"
nginx -t; if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl enable --now nginx; fi
if [[ "$DOMAIN_MODE" == public ]]; then
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
systemctl daemon-reload; systemctl enable --now fedora-server-certbot-renew.timer
else systemctl disable --now fedora-server-certbot-renew.timer 2>/dev/null || true; rm -f /etc/systemd/system/fedora-server-certbot-renew.service /etc/systemd/system/fedora-server-certbot-renew.timer; systemctl daemon-reload; fi
log "Nginx reverse proxy is ready."
