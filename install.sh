#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"
require_root; require_fedora; load_config; ensure_dirs
SELECTION_FILE="${STATE_DIR}/selected-apps.env"
RECONFIGURE="${RECONFIGURE:-false}"; DOMAIN_RECONFIGURE="${DOMAIN_RECONFIGURE:-false}"
usage() { cat <<EOF_USAGE
Fedora Server Home Services Setup

Usage:
  sudo ./install.sh                              Interactive installation/update
  sudo ./install.sh --all                        Install/update all applications
  sudo ./install.sh --app NAME                   Install/update one application
  sudo ./install.sh --reconfigure                Re-apply managed configuration
  sudo ./install.sh --reconfigure-domain         Change the saved domain/TLS mode
  sudo ./install.sh --all --reconfigure          Install/update all applications and recreate selected containers
  sudo ./install.sh --list                       List available applications
  sudo ./install.sh --help                       Show this help

Domain/TLS modes:
  local   - existing *.home names and the repository-generated local CA
  public  - real domain names and publicly trusted ACME certificates

Public mode uses DNS-01 validation. GoDaddy API credentials are required so Certbot can create
temporary DNS TXT records for validation. No inbound TCP 80 is required.
The installer does not modify router/DNS settings.
EOF_USAGE
}
write_domain_state_interactive() {
    local mode base prefix email answer old_mode old_base old_prefix
    old_mode="${DOMAIN_MODE:-local}"; old_base="${BASE_DOMAIN:-}"; old_prefix="${APP_SUBDOMAIN:-home}"
    if [[ -f "$DOMAIN_STATE" && "$DOMAIN_RECONFIGURE" != true ]]; then load_domain_state; ensure_godaddy_credentials; return; fi
    echo; echo "========================================"; echo " HTTPS / domain configuration"; echo "========================================"; echo
    if [[ -f "$DOMAIN_STATE" ]]; then
        echo "Current: ${old_mode}"; [[ "$old_mode" == public ]] && echo "Domain: ${old_prefix}.${old_base}"
        read -r -p "Change domain/TLS settings? [y/N]: " answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then load_domain_state; ensure_godaddy_credentials; return; fi
    fi
    echo "1) Local .home + generated local CA"; echo "2) Public domain + trusted ACME certificates"; read -r -p "Choose [1/2] (default 1): " mode; mode="${mode:-1}"
    case "$mode" in
      1) DOMAIN_MODE="local"; BASE_DOMAIN=""; APP_SUBDOMAIN="home" ;;
      2) DOMAIN_MODE="public"; read -r -p "Base domain (e.g. danielczank.eu): " base; base="${base%.}"; BASE_DOMAIN="$base"; read -r -p "Application subdomain prefix (default: home): " prefix; APP_SUBDOMAIN="${prefix:-home}"; read -r -p "ACME contact email (optional, press Enter to skip): " email; ACME_EMAIL="$email" ;;
      *) die "Invalid domain mode: ${mode}" ;;
    esac
    if [[ -f "$DOMAIN_STATE" ]]; then cp "$DOMAIN_STATE" "${STATE_DIR}/domain-previous.env"; chmod 600 "${STATE_DIR}/domain-previous.env"; fi
    save_domain_state; load_domain_state; ensure_godaddy_credentials
}
list_apps() { echo; echo "Available Docker applications:"; local i=1 app_id; while IFS= read -r app_id; do [[ -n "$app_id" ]] || continue; load_app_config "$app_id" || continue; printf '  [%d] %-15s %s:%s\n' "$i" "$APP_ID" "$APP_DOMAIN" "$APP_PORT"; i=$((i+1)); done < <(app_ids); echo; }
validate_app_id() { local app_id="$1"; [[ -d "$(app_dir "$app_id")" ]] || die "Unknown application: ${app_id}"; [[ -f "$(app_dir "$app_id")/app.conf" ]] || die "Application is missing app.conf: ${app_id}"; [[ -f "$(app_dir "$app_id")/compose.yml" ]] || die "Application is missing compose.yml: ${app_id}"; [[ -f "$(app_dir "$app_id")/install.sh" ]] || die "Application is missing install.sh: ${app_id}"; [[ -f "$(app_dir "$app_id")/verify.sh" ]] || die "Application is missing verify.sh: ${app_id}"; load_app_config "$app_id" || die "Application is disabled: ${app_id}"; }
save_selection() { local selected="$1"; cat > "$SELECTION_FILE" <<EOF_SELECTION
SELECTED_APPS=$(printf '%q' "$selected")
EOF_SELECTION
chmod 600 "$SELECTION_FILE"; }
select_apps_interactive() { local apps=() app_id answer selected=""; while IFS= read -r app_id; do [[ -n "$app_id" ]] && apps+=("$app_id"); done < <(app_ids); ((${#apps[@]} > 0)) || die "No Docker applications were found under ${SCRIPT_DIR}/apps."; echo; echo "========================================"; echo " Available applications"; echo "========================================"; for app_id in "${apps[@]}"; do load_app_config "$app_id" || continue; printf '  - %-15s %s  (host port %s)\n' "$APP_NAME" "$APP_DOMAIN" "$APP_PORT"; done; echo; read -r -p "Do you want to install ALL listed applications? [y/N]: " answer; if [[ "$answer" =~ ^[Yy]$ ]]; then selected="${apps[*]}"; else echo; echo "Select applications one by one:"; for app_id in "${apps[@]}"; do load_app_config "$app_id" || continue; read -r -p "Install ${APP_NAME} (${APP_DOMAIN}:${APP_PORT})? [y/N]: " answer; if [[ "$answer" =~ ^[Yy]$ ]]; then selected+="${selected:+ }${app_id}"; fi; done; fi; [[ -n "$selected" ]] || log "No optional applications selected. Infrastructure will still be configured."; save_selection "$selected"; SELECTED_APPS_RESULT="$selected"; }
show_final_selection() { local selected="$1" app_id; echo; echo "========================================"; echo " Final installation plan"; echo "========================================"; echo; echo "Domain/TLS mode: ${DOMAIN_MODE}"; if [[ "$DOMAIN_MODE" == public ]]; then echo "Base domain: ${BASE_DOMAIN}"; echo "Application zone: ${APP_SUBDOMAIN:+${APP_SUBDOMAIN}.}${BASE_DOMAIN}"; fi; echo; echo "Mandatory infrastructure:"; echo "  1. Base Fedora system packages"; echo "  2. Proxmox IP record"; echo "  3. Fedora static IP"; echo "  4. Docker Engine + Compose"; echo "  5. TLS certificates"; echo "  6. Nginx reverse proxy"; echo; echo "Selected applications:"; if [[ -n "$selected" ]]; then for app_id in $selected; do load_app_config "$app_id" || continue; printf '  - %s (%s -> port %s)\n' "$APP_NAME" "$APP_DOMAIN" "$APP_PORT"; done; else echo "  - none"; fi; if [[ "$RECONFIGURE" == true ]]; then echo; echo "RECONFIGURE mode: managed application containers will be force-recreated."; echo "Persistent application data is not deleted."; fi; echo; echo "Starting installation in 4 seconds..."; sleep 4; }
check_updates_first() { local rc; set +e; dnf -q check-update >/dev/null 2>&1; rc=$?; set -e; case "$rc" in 0) log "No pending Fedora package updates detected." ;; 100) warn "Fedora has pending updates."; read -r -p "Install all available updates now and stop the installer? [Y/n]: " answer; answer="${answer:-Y}"; if [[ "$answer" =~ ^[Yy]$ ]]; then dnf upgrade -y; echo; log "System update completed."; warn "If Fedora requires a reboot, reboot now."; warn "After reboot, run: sudo ${STACK_DIR}/install.sh"; exit 0; fi; die "Installation cannot continue while updates are pending." ;; *) die "Unable to determine Fedora update state (dnf check-update exit code: ${rc})." ;; esac; }
run_installation() { local selected="$1"; check_updates_first; export RECONFIGURE DOMAIN_RECONFIGURE; run_stage "01-system.sh"; run_stage "02-proxmox.sh"; run_stage "03-network.sh"; run_stage "04-docker.sh"; run_stage "40-certificates.sh"; run_stage "05-nginx.sh"; local app_id; for app_id in $selected; do validate_app_id "$app_id"; write_install_state "app:${app_id}" false; log "Installing/updating application: ${app_id}"; install_app "$app_id"; done; write_install_state "99-verify" false; bash "${SCRIPT_DIR}/scripts/99-verify.sh"; clear_install_state; echo; echo "========================================"; echo " Installation/update completed"; echo "========================================"; echo "Managed configuration has been reconciled with the repository."; }
main() { local mode="interactive" app_arg="" selected=""; while (($#)); do case "$1" in --all) mode="all" ;; --app) shift; [[ $# -gt 0 ]] || die "--app requires an application name."; mode="app"; app_arg="$1" ;; --reconfigure) RECONFIGURE=true ;; --reconfigure-domain) DOMAIN_RECONFIGURE=true ;; --list) mode="list" ;; --help|-h) usage; exit 0 ;; *) die "Unknown argument: $1 (use --help)." ;; esac; shift; done; log "Fedora Server Home Services Setup"; log "Repository: ${SCRIPT_DIR}"; if [[ "$mode" == list ]]; then load_domain_state; list_apps; exit 0; fi; write_domain_state_interactive; load_domain_state; ensure_godaddy_credentials; validate_config; case "$mode" in list) list_apps; exit 0 ;; all) selected="$(app_ids | paste -sd' ' -)" ;; app) validate_app_id "$app_arg"; selected="$app_arg" ;; interactive) select_apps_interactive; selected="${SELECTED_APPS_RESULT:-}" ;; esac; save_selection "$selected"; show_final_selection "$selected"; run_installation "$selected"; }
main "$@"
