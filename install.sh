#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"

require_root
require_fedora
load_config
validate_config
ensure_dirs

SELECTION_FILE="${STATE_DIR}/selected-apps.env"
RECONFIGURE="${RECONFIGURE:-false}"

usage() {
    cat <<EOF_USAGE
Fedora Server Home Services Setup

Usage:
  sudo ./install.sh                     Interactive installation/update
  sudo ./install.sh --all               Install/update all applications
  sudo ./install.sh --app NAME          Install/update one application
  sudo ./install.sh --reconfigure       Re-apply managed configuration and recreate selected containers
  sudo ./install.sh --all --reconfigure Install/update all applications and force container recreation
  sudo ./install.sh --list              List available applications
  sudo ./install.sh --help              Show this help

The infrastructure prerequisites are always checked and configured first.
Managed configuration files are written from the repository on every run.
Application containers are recreated only when required, unless --reconfigure is used.
Application data is kept in /opt/fedora-server-apps and is not removed by --reconfigure.
EOF_USAGE
}

list_apps() {
    echo
    echo "Available Docker applications:"
    local i=1 app_id name
    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue
        load_app_config "$app_id" || continue
        printf '  [%d] %-15s %s:%s\n' "$i" "$APP_ID" "$APP_DOMAIN" "$APP_PORT"
        i=$((i + 1))
    done < <(app_ids)
    echo
}

validate_app_id() {
    local app_id="$1"
    [[ -d "$(app_dir "$app_id")" ]] || die "Unknown application: ${app_id}"
    [[ -f "$(app_dir "$app_id")/app.conf" ]] || die "Application is missing app.conf: ${app_id}"
    [[ -f "$(app_dir "$app_id")/compose.yml" ]] || die "Application is missing compose.yml: ${app_id}"
    [[ -f "$(app_dir "$app_id")/install.sh" ]] || die "Application is missing install.sh: ${app_id}"
    [[ -f "$(app_dir "$app_id")/verify.sh" ]] || die "Application is missing verify.sh: ${app_id}"
    load_app_config "$app_id" || die "Application is disabled: ${app_id}"
}

save_selection() {
    local selected="$1"
    cat > "$SELECTION_FILE" <<EOF_SELECTION
SELECTED_APPS=$(printf '%q' "$selected")
EOF_SELECTION
    chmod 600 "$SELECTION_FILE"
}

select_apps_interactive() {
    local apps=() app_id answer selected="" name domain port
    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] && apps+=("$app_id")
    done < <(app_ids)

    ((${#apps[@]} > 0)) || die "No Docker applications were found under ${SCRIPT_DIR}/apps."

    echo
    echo "========================================"
    echo " Available applications"
    echo "========================================"
    for app_id in "${apps[@]}"; do
        load_app_config "$app_id" || continue
        printf '  - %-15s %s  (host port %s)\n' "$APP_NAME" "$APP_DOMAIN" "$APP_PORT"
    done

    echo
    read -r -p "Do you want to install ALL listed applications? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        selected="${apps[*]}"
    else
        echo
        echo "Select applications one by one:"
        for app_id in "${apps[@]}"; do
            load_app_config "$app_id" || continue
            read -r -p "Install ${APP_NAME} (${APP_DOMAIN}:${APP_PORT})? [y/N]: " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                selected+="${selected:+ }${app_id}"
            fi
        done
    fi

    if [[ -z "$selected" ]]; then
        log "No optional applications selected. Infrastructure will still be configured."
    fi

    save_selection "$selected"
    SELECTED_APPS_RESULT="$selected"
}

show_final_selection() {
    local selected="$1" app_id
    echo
    echo "========================================"
    echo " Final installation plan"
    echo "========================================"
    echo
    echo "Mandatory infrastructure:"
    echo "  1. Base Fedora system packages"
    echo "  2. Proxmox IP record"
    echo "  3. Fedora static IP"
    echo "  4. Docker Engine + Compose"
    echo "  5. Local CA / TLS certificates"
    echo "  6. Nginx reverse proxy"
    echo
    echo "Selected applications:"
    if [[ -n "$selected" ]]; then
        for app_id in $selected; do
            load_app_config "$app_id" || continue
            printf '  - %s (%s -> port %s)\n' "$APP_NAME" "$APP_DOMAIN" "$APP_PORT"
        done
    else
        echo "  - none"
    fi
    if [[ "$RECONFIGURE" == true ]]; then
        echo
        echo "RECONFIGURE mode: managed application containers will be force-recreated."
        echo "Persistent application data is not deleted."
    fi
    echo
    echo "Starting installation in 4 seconds..."
    sleep 4
}

check_updates_first() {
    local rc
    set +e
    dnf -q check-update >/dev/null 2>&1
    rc=$?
    set -e

    case "$rc" in
        0)
            log "No pending Fedora package updates detected."
            ;;
        100)
            warn "Fedora has pending updates."
            read -r -p "Install all available updates now and stop the installer? [Y/n]: " answer
            answer="${answer:-Y}"
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                dnf upgrade -y
                echo
                log "System update completed."
                warn "If Fedora requires a reboot, reboot now."
                warn "After reboot, run: sudo ${STACK_DIR}/install.sh"
                exit 0
            fi
            die "Installation cannot continue while updates are pending."
            ;;
        *)
            die "Unable to determine Fedora update state (dnf check-update exit code: ${rc})."
            ;;
    esac
}

run_installation() {
    local selected="$1"
    check_updates_first

    export RECONFIGURE

    run_stage "01-system.sh"
    run_stage "02-proxmox.sh"
    run_stage "03-network.sh"
    run_stage "04-docker.sh"
    run_stage "40-certificates.sh"
    run_stage "05-nginx.sh"

    local app_id
    for app_id in $selected; do
        validate_app_id "$app_id"
        write_install_state "app:${app_id}" false
        log "Installing/updating application: ${app_id}"
        install_app "$app_id"
    done

    write_install_state "99-verify" false
    bash "${SCRIPT_DIR}/scripts/99-verify.sh"
    clear_install_state

    echo
    echo "========================================"
    echo " Installation/update completed"
    echo "========================================"
    echo "Managed configuration has been reconciled with the repository."
}

main() {
    local mode="interactive" app_arg="" selected=""

    while (($#)); do
        case "$1" in
            --all)
                mode="all"
                ;;
            --app)
                shift
                [[ $# -gt 0 ]] || die "--app requires an application name."
                mode="app"
                app_arg="$1"
                ;;
            --reconfigure)
                RECONFIGURE=true
                ;;
            --list)
                mode="list"
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1 (use --help)."
                ;;
        esac
        shift
    done

    log "Fedora Server Home Services Setup"
    log "Repository: ${SCRIPT_DIR}"

    case "$mode" in
        list)
            list_apps
            exit 0
            ;;
        all)
            selected="$(app_ids | paste -sd' ' -)"
            ;;
        app)
            validate_app_id "$app_arg"
            selected="$app_arg"
            ;;
        interactive)
            select_apps_interactive
            selected="${SELECTED_APPS_RESULT:-}"
            ;;
    esac

    save_selection "$selected"
    show_final_selection "$selected"
    run_installation "$selected"
}

main "$@"
