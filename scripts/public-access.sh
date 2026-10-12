#!/usr/bin/env bash

PUBLIC_ACCESS_STATE="${STATE_DIR}/public-access.env"
GODADDY_DDNS_STATE="${STATE_DIR}/godaddy-ddns.env"
PUBLIC_DDNS_DIR="${STATE_DIR}/ddns.d"
PUBLIC_DEFAULT_CIDRS=("127.0.0.1/32" "::1/128" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "fc00::/7")

publish_public_ddns_state() {
    local staged_dir="$1"
    local backup_dir="${PUBLIC_DDNS_DIR}.old.$$"
    rm -rf -- "$backup_dir"
    if [[ -e "$PUBLIC_DDNS_DIR" ]]; then
        mv -- "$PUBLIC_DDNS_DIR" "$backup_dir" || die "Unable to back up existing DDNS state."
    fi
    if mv -- "$staged_dir" "$PUBLIC_DDNS_DIR"; then
        rm -rf -- "$backup_dir"
        return 0
    fi
    if [[ -e "$backup_dir" ]]; then
        mv -- "$backup_dir" "$PUBLIC_DDNS_DIR" || die "Unable to restore previous DDNS state."
    fi
    die "Unable to publish generated DDNS state."
}

load_public_access_state() {
    unset PUBLIC_APPS PUBLIC_ACCESS_CONFIGURED_APPS LOCAL_CIDRS
    PUBLIC_APPS=""
    PUBLIC_ACCESS_CONFIGURED_APPS=""
    LOCAL_CIDRS=("${PUBLIC_DEFAULT_CIDRS[@]}")
    if [[ -f "$PUBLIC_ACCESS_STATE" ]]; then
        source "$PUBLIC_ACCESS_STATE"
        PUBLIC_APPS="${PUBLIC_APPS:-}"
        PUBLIC_ACCESS_CONFIGURED_APPS="${PUBLIC_ACCESS_CONFIGURED_APPS:-}"
        declare -p LOCAL_CIDRS >/dev/null 2>&1 || LOCAL_CIDRS=("${PUBLIC_DEFAULT_CIDRS[@]}")
    fi
}

save_public_access_state() {
    install -d -m 0750 "$STATE_DIR"
    {
        printf 'PUBLIC_APPS=%q\n' "$PUBLIC_APPS"
        printf 'PUBLIC_ACCESS_CONFIGURED_APPS=%q\n' "$PUBLIC_ACCESS_CONFIGURED_APPS"
        printf 'LOCAL_CIDRS=(\n'
        printf '    %q\n' "${LOCAL_CIDRS[@]}"
        printf ')\n'
    } > "$PUBLIC_ACCESS_STATE"
    chown root:root "$PUBLIC_ACCESS_STATE"
    chmod 600 "$PUBLIC_ACCESS_STATE"
}

load_godaddy_ddns_state() {
    unset GODADDY_DDNS_ENABLED
    # Automatic DDNS is opt-in, so the server does not probe the public IP by default.
    GODADDY_DDNS_ENABLED="false"
    if [[ -f "$GODADDY_DDNS_STATE" ]]; then
        source "$GODADDY_DDNS_STATE"
    fi
    GODADDY_DDNS_ENABLED="${GODADDY_DDNS_ENABLED:-false}"

    case "$GODADDY_DDNS_ENABLED" in
        true|false) ;;
        *) die "Invalid GODADDY_DDNS_ENABLED value in ${GODADDY_DDNS_STATE}. Use true or false." ;;
    esac
}

save_godaddy_ddns_state() {
    install -d -m 0750 "$STATE_DIR"
    printf 'GODADDY_DDNS_ENABLED=%q\n' "$GODADDY_DDNS_ENABLED" > "$GODADDY_DDNS_STATE"
    chown root:root "$GODADDY_DDNS_STATE"
    chmod 600 "$GODADDY_DDNS_STATE"
}

configure_godaddy_ddns_interactive() {
    local answer default

    load_godaddy_ddns_state
    echo
    echo "========================================"
    echo " GoDaddy automatic DDNS updates"
    echo "========================================"
    echo "This controls automatic A/AAAA record updates from this server."
    echo "It does not change public Nginx access, certificate issuance/renewal, or existing DNS records."
    echo

    if [[ "$GODADDY_DDNS_ENABLED" == "true" ]]; then
        read -r -p "Enable automatic GoDaddy DDNS updates? [Y/n]: " answer
        default="Y"
    else
        read -r -p "Enable automatic GoDaddy DDNS updates? [y/N]: " answer
        default="N"
    fi
    answer="${answer:-$default}"

    case "$answer" in
        [Yy]*) GODADDY_DDNS_ENABLED="true" ;;
        [Nn]*) GODADDY_DDNS_ENABLED="false" ;;
        *) die "Please answer yes or no." ;;
    esac

    save_godaddy_ddns_state
    if [[ "$GODADDY_DDNS_ENABLED" == "true" ]]; then
        echo "Automatic GoDaddy DDNS updates are enabled."
    else
        echo "Automatic GoDaddy DDNS updates are disabled. Existing DNS records will be left unchanged."
    fi
}

is_public_app() {
    local app_id="$1"
    [[ " ${PUBLIC_APPS:-} " == *" ${app_id} "* ]]
}

public_access_nginx_rules() {
    local cidr
    for cidr in "${LOCAL_CIDRS[@]}"; do
        printf 'allow %s; ' "$cidr"
    done
    printf 'deny all;'
}

cidr_list_valid() {
    python3 - "$1" <<'PY'
import ipaddress
import sys
items = sys.argv[1].split()
if not items:
    raise SystemExit(1)
try:
    for item in items:
        ipaddress.ip_network(item, strict=False)
except ValueError:
    raise SystemExit(1)
PY
}

configure_public_access_interactive() {
    local selected="$1"
    local force="${2:-false}"
    local app_id answer cidr_input candidate
    local configured public kept item
    local -a new_cidrs=() candidates=()

    load_public_access_state
    configured="${PUBLIC_ACCESS_CONFIGURED_APPS:-}"
    public="${PUBLIC_APPS:-}"

    if [[ "${DOMAIN_MODE:-local}" != "public" ]]; then
        save_public_access_state
        return 0
    fi

    echo
    echo "========================================"
    echo " Public access and dynamic DNS"
    echo "========================================"
    echo
    echo "Only applications enabled here receive public Nginx access."
    echo "Automatic GoDaddy DDNS updates are controlled by a separate setting."
    echo "Unselected applications remain local/VPN-only."
    echo

    for candidate in $(app_ids); do
        if [[ " ${selected} " == *" ${candidate} "* ]] || app_is_installed "$candidate"; then
            candidates+=("$candidate")
        fi
    done

    for app_id in "${candidates[@]}"; do
        [[ -n "$app_id" ]] || continue
        load_app_config "$app_id" || continue
        [[ "${APP_NGINX_ENABLED:-true}" == "true" ]] || continue
        if [[ "$force" != true && " ${configured} " == *" ${app_id} "* ]]; then
            continue
        fi

        printf '\nApplication: %s\nDomain: %s\n' "$APP_NAME" "${APP_DOMAIN}"
        read -r -p "Allow public internet access for this application? [y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            [[ " ${public} " == *" ${app_id} "* ]] || public+="${public:+ }${app_id}"
        else
            kept=""
            for item in $public; do
                [[ "$item" == "$app_id" ]] && continue
                kept+="${kept:+ }${item}"
            done
            public="$kept"
        fi
        [[ " ${configured} " == *" ${app_id} "* ]] || configured+="${configured:+ }${app_id}"
    done

    if [[ "$force" == true || ! -f "$PUBLIC_ACCESS_STATE" || -z "${configured//[[:space:]]/}" ]]; then
        echo
        echo "Enter the LAN and VPN CIDR ranges allowed to reach Cockpit and Proxmox."
        echo "Default ranges cover common private LAN/VPN networks."
        printf 'Default:'
        printf ' %s' "${PUBLIC_DEFAULT_CIDRS[@]}"
        echo
        read -r -p "Allowed CIDRs separated by spaces [default above]: " cidr_input
        cidr_input="${cidr_input:-${PUBLIC_DEFAULT_CIDRS[*]}}"
        cidr_list_valid "$cidr_input" || die "Invalid LAN/VPN CIDR list."
        read -r -a new_cidrs <<< "$cidr_input"
        LOCAL_CIDRS=("${new_cidrs[@]}")
    fi

    PUBLIC_APPS="$public"
    PUBLIC_ACCESS_CONFIGURED_APPS="$configured"
    save_public_access_state
}

remove_public_app() {
    local app_id="$1"
    local item updated=""
    load_public_access_state
    for item in $PUBLIC_APPS; do
        [[ "$item" == "$app_id" ]] && continue
        updated+="${updated:+ }${item}"
    done
    PUBLIC_APPS="$updated"
    updated=""
    for item in $PUBLIC_ACCESS_CONFIGURED_APPS; do
        [[ "$item" == "$app_id" ]] && continue
        updated+="${updated:+ }${item}"
    done
    PUBLIC_ACCESS_CONFIGURED_APPS="$updated"
    rm -f "${PUBLIC_DDNS_DIR}/${app_id}.conf"
    save_public_access_state
}

sync_public_ddns_state() {
    local app_id domain zone best_zone candidate
    local -a domains=() zones=() configured_zones=()
    local -A seen=()

    load_public_access_state
    local staged_dir="${PUBLIC_DDNS_DIR}.new.$$"
    rm -rf -- "$staged_dir"
    install -d -m 0700 "$staged_dir"

    load_godaddy_ddns_state
    if [[ "$GODADDY_DDNS_ENABLED" != "true" ]]; then
        # No app-domain checks or public-IP lookups are needed when DDNS is disabled.
        publish_public_ddns_state "$staged_dir"
        return 0
    fi

    if [[ "${DOMAIN_MODE:-local}" != "public" || -z "${PUBLIC_APPS:-}" ]]; then
        publish_public_ddns_state "$staged_dir"
        return 0
    fi

    [[ -s "${STATE_DIR}/godaddy-zones.conf" ]] || {
        rm -rf -- "$staged_dir"
        die "Public apps require configured GoDaddy DNS zones."
    }
    unset GODADDY_DNS_ZONES
    source "${STATE_DIR}/godaddy-zones.conf"
    configured_zones=("${GODADDY_DNS_ZONES[@]}")

    for app_id in $PUBLIC_APPS; do
        load_app_config "$app_id" || continue
        [[ "${APP_NGINX_ENABLED:-true}" == "true" ]] || continue
        domains=()
        zones=()
        seen=()

        for candidate in "${APP_DOMAIN:-}" "${APP_CANONICAL_DOMAIN:-}" ${APP_DOMAIN_ALIASES:-}; do
            [[ -n "$candidate" ]] || continue
            valid_hostname "$candidate" || die "Invalid public domain for ${app_id}: ${candidate}"
            [[ -n "${seen[$candidate]:-}" ]] && continue
            seen["$candidate"]=1
            best_zone=""
            for zone in "${configured_zones[@]}"; do
                zone="${zone%.}"
                if [[ "$candidate" == "$zone" || "$candidate" == *".${zone}" ]]; then
                    if ((${#zone} > ${#best_zone})); then
                        best_zone="$zone"
                    fi
                fi
            done
            [[ -n "$best_zone" ]] || die "Public domain ${candidate} for ${app_id} does not match a configured GoDaddy DNS zone."
            domains+=("$candidate")
            zones+=("$best_zone")
        done

        ((${#domains[@]} > 0)) || continue
        {
            printf 'DDNS_APP_ID=%q\n' "$app_id"
            printf 'DDNS_DOMAINS=(\n'
            printf '    %q\n' "${domains[@]}"
            printf ')\n'
            printf 'DDNS_ZONES=(\n'
            printf '    %q\n' "${zones[@]}"
            printf ')\n'
        } > "${staged_dir}/${app_id}.conf"
        chown root:root "${staged_dir}/${app_id}.conf"
        chmod 600 "${staged_dir}/${app_id}.conf"
    done

    publish_public_ddns_state "$staged_dir"
}
