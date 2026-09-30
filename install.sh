#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"
require_root; require_fedora; load_config; ensure_dirs
SELECTION_FILE="${STATE_DIR}/selected-apps.env"
RECONFIGURE="${RECONFIGURE:-false}"; DOMAIN_RECONFIGURE="${DOMAIN_RECONFIGURE:-false}"
usage(){ cat <<'USAGE'
Fedora Server Home Services Setup

Usage:
  sudo ./install.sh                 Interactive state-aware setup/update/remove menu
  sudo ./install.sh --all           Install/update all applications
  sudo ./install.sh --app NAME      Install/update one application
  sudo ./install.sh --reconfigure   Re-apply saved configuration
  sudo ./install.sh --reconfigure-domain  Change saved domain/TLS settings
  sudo ./install.sh --list          Show detected and available applications
  sudo ./install.sh --help          Show this help

Public mode uses one Let's Encrypt certificate containing the application-zone apex
and wildcard, validated through the GoDaddy DNS-01 API.
USAGE
}
state_exists(){ [[ -d "$STATE_DIR" ]] && find "$STATE_DIR" -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .; }
detected_app_ids(){ local a; while IFS= read -r a; do [[ -n "$a" ]] && app_is_installed "$a" && printf '%s\n' "$a"; done < <(app_ids); }
detected_app_count(){ detected_app_ids | grep -c . || true; }
show_detection(){
  local n; n="$(detected_app_count)"
  echo; echo '========================================'; echo ' Existing installation detection'; echo '========================================'; echo
  if (( n == 0 )) && ! state_exists; then
    echo 'No installed applications were detected.'
    echo 'No saved installer settings were detected.'
    echo 'This is treated as a new installation.'
    echo 'You will go through the complete configuration and application selection process.'
    return
  fi
  if (( n > 0 )); then
    echo 'Detected installed applications:'
    while IFS= read -r a; do load_app_config "$a" || continue; printf '  - %s (%s)\n' "$APP_NAME" "$a"; done < <(detected_app_ids)
  else echo 'No installed applications were detected.'; fi
  echo
  if [[ -f "$DOMAIN_STATE" ]]; then load_domain_state; echo "Saved domain/TLS settings: ${DOMAIN_MODE}"; [[ "$DOMAIN_MODE" == public ]] && echo "Application zone: ${APP_SUBDOMAIN}.${BASE_DOMAIN}"; else echo 'No saved domain/TLS settings were detected.'; fi
  [[ -f "$NETWORK_STATE" ]] && echo "Saved network settings: present" || echo 'Saved network settings: not found.'
  [[ -f "$PROXMOX_STATE" ]] && echo "Saved Proxmox settings: present" || echo 'Saved Proxmox settings: not found.'
  [[ -f "$SELECTION_FILE" ]] && { source "$SELECTION_FILE"; echo "Saved application selection: ${SELECTED_APPS:-none}"; } || echo 'Saved application selection: not found.'
  [[ -f "$GODADDY_CREDENTIALS" ]] && echo 'Saved GoDaddy PAT: present' || true
}
save_selection(){ cat > "$SELECTION_FILE" <<EOFSEL
SELECTED_APPS=$(printf '%q' "$1")
EOFSEL
chmod 600 "$SELECTION_FILE"; }
show_apps(){ local a; echo; echo 'Available applications:'; while IFS= read -r a; do [[ -n "$a" ]] || continue; load_app_config "$a" || continue; printf '  - %s (%s, host port %s)\n' "$APP_NAME" "$APP_ID" "$APP_PORT"; done < <(app_ids); echo; }
validate_app_id(){ local a="$1"; [[ -d "$(app_dir "$a")" ]] || die "Unknown application: $a"; [[ -f "$(app_dir "$a")/app.conf" && -f "$(app_dir "$a")/compose.yml" && -f "$(app_dir "$a")/install.sh" && -f "$(app_dir "$a")/verify.sh" ]] || die "Application is incomplete: $a"; load_app_config "$a" || die "Application is disabled: $a"; }
write_domain_state_interactive(){
  local answer mode base prefix email
  if [[ -f "$DOMAIN_STATE" && "$DOMAIN_RECONFIGURE" != true ]]; then load_domain_state; ensure_godaddy_credentials; return; fi
  echo; echo '========================================'; echo ' HTTPS / domain configuration'; echo '========================================'; echo
  echo 'Public mode gives normal browser-trusted HTTPS through Let’s Encrypt.'
  echo 'Local mode uses a private CA that must be trusted on each client device.'
  read -r -p 'Use public trusted HTTPS with a real domain? [y/N]: ' answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    DOMAIN_MODE=public
    read -r -p 'What is the base domain you control, e.g. example.com? ' base; base="${base%.}"; [[ -n "$base" ]] || die 'Base domain cannot be empty.'; BASE_DOMAIN="$base"
    read -r -p 'What application subdomain prefix should be used, e.g. home? [home]: ' prefix; APP_SUBDOMAIN="${prefix:-home}"
    read -r -p 'What email should Let’s Encrypt use for certificate notices? Press Enter to skip: ' email; ACME_EMAIL="$email"
    save_domain_state; load_domain_state; ensure_godaddy_credentials
  else
    DOMAIN_MODE=local; BASE_DOMAIN=''; APP_SUBDOMAIN=home; ACME_EMAIL=''; save_domain_state; load_domain_state
  fi
}
select_apps_interactive(){
  local a answer selected=''
  echo; echo '========================================'; echo ' Application selection'; echo '========================================'; echo 'Each question asks whether this application should be managed.'; echo
  while IFS= read -r a; do [[ -n "$a" ]] || continue; load_app_config "$a" || continue; read -r -p "Install/update ${APP_NAME} (${APP_DOMAIN}, host port ${APP_PORT})? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && selected+="${selected:+ }${a}"; done < <(app_ids)
  save_selection "$selected"; SELECTED_APPS_RESULT="$selected"
}
show_plan(){ local selected="$1" a; echo; echo '========================================'; echo ' Planned operation'; echo '========================================'; echo; echo "Domain/TLS mode: $DOMAIN_MODE"; [[ "$DOMAIN_MODE" == public ]] && { echo "Base domain: $BASE_DOMAIN"; echo "Application zone: ${APP_SUBDOMAIN}.${BASE_DOMAIN}"; echo "Certificate: ${APP_SUBDOMAIN}.${BASE_DOMAIN} + *.${APP_SUBDOMAIN}.${BASE_DOMAIN}"; }; echo; echo 'Selected applications:'; if [[ -n "$selected" ]]; then for a in $selected; do load_app_config "$a" || continue; printf '  - %s (%s -> port %s)\n' "$APP_NAME" "$APP_DOMAIN" "$APP_PORT"; done; else echo '  - none'; fi; echo; }
check_updates_first(){ local rc; set +e; dnf -q check-update >/dev/null 2>&1; rc=$?; set -e; case "$rc" in 0) log 'No pending Fedora package updates detected.';;100) warn 'Fedora has pending updates.'; read -r -p 'Install available Fedora updates now and stop so you can reboot if needed? [Y/n]: ' a; a="${a:-Y}"; [[ "$a" =~ ^[Yy]$ ]] || die 'Installation cannot continue while Fedora updates are pending.'; dnf upgrade -y; warn 'If Fedora requires a reboot, reboot now, then run the installer again.'; exit 0;;*) die "Unable to determine Fedora update state (dnf exit code $rc).";;esac; }
run_installation(){ local selected="$1" a; check_updates_first; export RECONFIGURE DOMAIN_RECONFIGURE; run_stage 01-system.sh; run_stage 02-proxmox.sh; run_stage 03-network.sh; run_stage 04-docker.sh; run_stage 40-certificates.sh; run_stage 05-nginx.sh; for a in $selected; do validate_app_id "$a"; write_install_state "app:$a" false; log "Installing/updating application: $a"; install_app "$a"; done; write_install_state 99-verify false; bash "${SCRIPT_DIR}/scripts/99-verify.sh"; clear_install_state; echo; echo 'Installation/update completed.'; }
update_installed(){ local selected; load_domain_state; [[ -f "$SELECTION_FILE" ]] && source "$SELECTION_FILE"; selected="${SELECTED_APPS:-$(detected_app_ids | paste -sd' ' -)}"; [[ -n "$selected" ]] || { echo 'No installed applications were detected. Choose settings mode to configure applications.'; return; }; read -r -p 'Update the saved installation and reconcile its configuration now? [Y/n]: ' a; a="${a:-Y}"; [[ "$a" =~ ^[Yy]$ ]] || return; RECONFIGURE=false; DOMAIN_RECONFIGURE=false; validate_config; show_plan "$selected"; run_installation "$selected"; }
modify_settings(){ local selected answer; DOMAIN_RECONFIGURE=true; write_domain_state_interactive; select_apps_interactive; selected="$SELECTED_APPS_RESULT"; RECONFIGURE=true; DOMAIN_RECONFIGURE=false; validate_config; show_plan "$selected"; read -r -p 'Apply these changed settings and recreate affected containers? [Y/n]: ' answer; answer="${answer:-Y}"; [[ "$answer" =~ ^[Yy]$ ]] || return; run_installation "$selected"; }
remove_application(){
  local a answer data_answer runtime compose new_selection item
  show_apps; read -r -p 'Which application ID should be removed, e.g. joplin, portainer, or vaultwarden? ' a; validate_app_id "$a"; load_app_config "$a"; runtime="$(app_runtime_dir "$a")"; compose="$(app_compose_file "$a")"
  read -r -p "Also delete ${APP_NAME}'s persistent Docker volumes and data? [y/N]: " data_answer
  read -r -p "Confirm removal of ${APP_NAME}? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] || { echo 'Removal cancelled.'; return; }
  if [[ -f "$compose" ]]; then (cd "$runtime"; if [[ "$data_answer" =~ ^[Yy]$ ]]; then docker compose -f "$compose" down --remove-orphans --volumes; else docker compose -f "$compose" down --remove-orphans; fi); fi
  rm -rf "$runtime"; app_nginx_remove "$a"; new_selection=''; [[ -f "$SELECTION_FILE" ]] && source "$SELECTION_FILE"; for item in ${SELECTED_APPS:-}; do [[ "$item" == "$a" ]] || new_selection+="${new_selection:+ }$item"; done; save_selection "$new_selection"; [[ -f "${STATE_DIR}/managed-nginx-apps" ]] && { grep -vxF "$a" "${STATE_DIR}/managed-nginx-apps" > "${STATE_DIR}/managed-nginx-apps.tmp" || true; mv "${STATE_DIR}/managed-nginx-apps.tmp" "${STATE_DIR}/managed-nginx-apps"; }; nginx -t >/dev/null 2>&1 && systemctl reload nginx || true; echo "${APP_NAME} has been removed."; }
remove_server_package(){
  local answer data_answer a runtime compose certbot cert_name
  echo; echo 'This removes the repository-managed service package: containers, managed Nginx config, renewal timer, TLS material, installer state and Certbot environment.'; echo 'It does not remove Fedora, Docker packages, unrelated Docker data, router/DNS settings, or this Git repository.'; echo
  read -r -p 'Also delete persistent Docker volumes belonging to managed applications? [y/N]: ' data_answer
  read -r -p 'Confirm removal of the complete managed server package? [y/N]: ' answer; [[ "$answer" =~ ^[Yy]$ ]] || { echo 'Removal cancelled.'; return; }
  while IFS= read -r a; do [[ -n "$a" ]] || continue; load_app_config "$a" || continue; runtime="$(app_runtime_dir "$a")"; compose="$(app_compose_file "$a")"; if [[ -f "$compose" ]]; then (cd "$runtime"; if [[ "$data_answer" =~ ^[Yy]$ ]]; then docker compose -f "$compose" down --remove-orphans --volumes || true; else docker compose -f "$compose" down --remove-orphans || true; fi); fi; rm -rf "$runtime"; done < <(app_ids)
  rm -f "${NGINX_RUNTIME_DIR}/fedora-server.conf" "${NGINX_RUNTIME_DIR}/proxmox.conf"; if [[ -f "${STATE_DIR}/managed-nginx-apps" ]]; then while IFS= read -r a; do [[ -n "$a" ]] && rm -f "${NGINX_RUNTIME_DIR}/${a}.conf"; done < "${STATE_DIR}/managed-nginx-apps"; fi; rm -f "${STATE_DIR}/managed-nginx-apps"
  systemctl disable --now fedora-server-certbot-renew.timer 2>/dev/null || true; rm -f /etc/systemd/system/fedora-server-certbot-renew.service /etc/systemd/system/fedora-server-certbot-renew.timer; systemctl daemon-reload
  certbot=''; [[ -x "${STACK_DIR}/certbot-venv/bin/certbot" ]] && certbot="${STACK_DIR}/certbot-venv/bin/certbot"; [[ -z "$certbot" && -x "$(command -v certbot 2>/dev/null || true)" ]] && certbot="$(command -v certbot)"; if [[ -n "$certbot" ]]; then "$certbot" certificates 2>/dev/null | awk '/Certificate Name: /{print $3}' | while IFS= read -r cert_name; do [[ -n "$cert_name" ]] && "$certbot" delete --cert-name "$cert_name" --non-interactive >/dev/null 2>&1 || true; done; fi
  rm -rf "$TLS_DIR" "$RUNTIME_APP_DIR"; rm -rf "$STACK_DIR/certbot-venv"; rm -f "$STACK_DIR/godaddy-dns-hook.sh" "$NETWORK_STATE" "$PROXMOX_STATE" "$DOMAIN_STATE" "${STATE_DIR}/domain-previous.env" "$SELECTION_FILE" "$GODADDY_CREDENTIALS" "$INSTALL_STATE"; nginx -t >/dev/null 2>&1 && systemctl reload nginx || true; echo 'Managed server package removal completed.'; }
interactive_menu(){
  if [[ "$(detected_app_count)" == 0 && ! state_exists ]]; then
    show_detection; write_domain_state_interactive; select_apps_interactive; show_plan "$SELECTED_APPS_RESULT"; read -r -p 'Start the complete installation now using this plan? [Y/n]: ' a; a="${a:-Y}"; [[ "$a" =~ ^[Yy]$ ]] || { echo 'Installation cancelled. Saved settings remain available.'; return; }; run_installation "$SELECTED_APPS_RESULT"; return
  fi
  show_detection; echo; echo 'What would you like to do?'; echo '  1) Update the existing installation'; echo '  2) Modify saved settings and application selection'; echo '  3) Remove one application'; echo '  4) Remove the complete managed server package'; echo '  5) Exit without changes'; echo; read -r -p 'Choose one action [1-5]: ' action; case "$action" in 1) update_installed;;2) modify_settings;;3) remove_application;;4) remove_server_package;;5) echo 'No changes made.';;*) die "Invalid menu selection: $action";;esac; }
main(){ local mode=interactive app_arg='' selected answer; while (($#)); do case "$1" in --all) mode=all;;--app) shift; [[ $# -gt 0 ]] || die '--app requires an application name.'; mode=app; app_arg="$1";;--reconfigure) RECONFIGURE=true;;--reconfigure-domain) DOMAIN_RECONFIGURE=true;;--list) mode=list;;--help|-h) usage; exit 0;;*) die "Unknown argument: $1 (use --help).";;esac; shift; done; log 'Fedora Server Home Services Setup'; log "Repository: $SCRIPT_DIR"; if [[ "$mode" == list ]]; then show_detection; show_apps; exit 0; fi; if [[ "$mode" == interactive ]]; then interactive_menu; exit 0; fi; write_domain_state_interactive; if [[ "$mode" == all ]]; then selected="$(app_ids | paste -sd' ' -)"; else validate_app_id "$app_arg"; selected="$app_arg"; fi; validate_config; save_selection "$selected"; show_plan "$selected"; read -r -p 'Apply this installation/update plan now? [Y/n]: ' answer; answer="${answer:-Y}"; [[ "$answer" =~ ^[Yy]$ ]] || exit 0; run_installation "$selected"; }
main "$@"
