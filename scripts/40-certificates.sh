#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
validate_config
ensure_dirs

[[ -f "$NETWORK_STATE" ]] || die "Network state missing. Run the network stage first."
source "$NETWORK_STATE"
valid_ipv4 "${STATIC_IP:-}" || die "Invalid stored Fedora IP: ${STATIC_IP:-unset}"

[[ -f "$PROXMOX_STATE" ]] || die "Proxmox state missing. Run the Proxmox stage first."
source "$PROXMOX_STATE"
valid_ipv4 "${PROXMOX_IP:-}" || die "Invalid stored Proxmox IP: ${PROXMOX_IP:-unset}"

SELECTION_FILE="${STATE_DIR}/selected-apps.env"
SELECTED_APPS=""
if [[ -f "$SELECTION_FILE" ]]; then
    source "$SELECTION_FILE"
    SELECTED_APPS="${SELECTED_APPS:-}"
fi

load_tls_app_config() {
    local id="$1" file
    unset APP_ID APP_NAME APP_DOMAIN APP_PORT APP_EXTRA_PORTS APP_CONTAINER APP_TLS_NAME APP_NGINX_ENABLED APP_CERTIFICATE_ENABLED APP_TLS_MODE APP_DOMAIN_ALIASES APP_CANONICAL_DOMAIN APP_SOURCE_TYPE APP_SOURCE_URL APP_SOURCE_REF APP_DEPLOY_TYPE
    file="$(app_dir "$id")/app.conf"
    [[ -f "$file" ]] || return 1
    source "$file"
    [[ "${APP_ID:-}" == "$id" ]] || die "Invalid APP_ID in $file"
    [[ "${APP_ENABLED:-true}" == true ]]
}

certificate_apps() {
    local id
    declare -A seen=()
    for id in $SELECTED_APPS; do
        [[ -n "$id" ]] || continue
        seen["$id"]=1
        printf '%s\n' "$id"
    done
    while IFS= read -r id; do
        [[ -n "$id" && -z "${seen[$id]:-}" ]] || continue
        app_is_installed "$id" && printf '%s\n' "$id"
    done < <(app_ids)
}

local_generate_ca() {
    local key="${TLS_DIR}/ca.key" cert="${TLS_DIR}/ca.crt"
    [[ -s "$key" && -s "$cert" ]] && return 0
    log "Generating local Certificate Authority"
    openssl genrsa -out "$key" 4096
    chmod 600 "$key"
    openssl req -x509 -new -sha256 -key "$key" -out "$cert" -days 3650 -subj "/C=XX/O=Home Lab/CN=Home Lab Local CA"
    chmod 644 "$cert"
}

local_generate_leaf() {
    local name="$1" domain="$2" ip="$3"
    local key="${TLS_DIR}/${name}.key" cert="${TLS_DIR}/${name}.crt"
    local csr="${TLS_DIR}/${name}.csr" ext="${TLS_DIR}/${name}.ext"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s,IP:%s\n' "$domain" "$ip" > "$ext"
    openssl genrsa -out "$key" 2048
    openssl req -new -key "$key" -out "$csr" -subj "/C=XX/O=Home Lab/CN=${domain}"
    openssl x509 -req -in "$csr" -CA "${TLS_DIR}/ca.crt" -CAkey "${TLS_DIR}/ca.key" -CAcreateserial -out "$cert" -days 365 -sha256 -extfile "$ext"
    chmod 600 "$key"
    chmod 644 "$cert"
    rm -f "$csr" "$ext" "${TLS_DIR}/ca.srl"
}

certificate_needs_regeneration() {
    local cert="$1" domain="$2" ip="$3"
    [[ -s "$cert" ]] || return 0
    openssl x509 -checkend $((30 * 86400)) -noout -in "$cert" >/dev/null 2>&1 || return 0
    openssl x509 -in "$cert" -noout -ext subjectAltName | grep -Fq "DNS:${domain}" || return 0
    openssl x509 -in "$cert" -noout -ext subjectAltName | grep -Fq "IP Address:${ip}" || return 0
    return 1
}

certbot_bin() {
    if [[ -x "${STACK_DIR}/certbot-venv/bin/certbot" ]]; then
        printf '%s' "${STACK_DIR}/certbot-venv/bin/certbot"
    else
        command -v certbot 2>/dev/null || true
    fi
}

certbot_delete() {
    local name="$1" bin
    bin="$(certbot_bin)"
    [[ -n "$bin" ]] && "$bin" delete --cert-name "$name" --non-interactive >/dev/null 2>&1 || true
}

app_tls_mode() {
    local id="$1"
    load_tls_app_config "$id" || return 1
    printf '%s' "${APP_TLS_MODE:-$(certificate_mode)}"
}

if [[ -f "${STATE_DIR}/domain-previous.env" ]]; then
    previous_state="${STATE_DIR}/domain-previous.env"
    previous_mode=""

    previous_mode="$(
        set -a
        source "$previous_state"
        printf '%s' "${DOMAIN_MODE:-}"
    )"

    rm -f "$previous_state"

    if [[ "$previous_mode" == "local" ]]; then
        find "$TLS_DIR" -mindepth 1 -maxdepth 1 -type f \
            \( -name '*.crt' -o -name '*.key' -o -name '*.csr' -o -name '*.ext' \) \
            ! -name 'ca.crt' \
            ! -name 'ca.key' \
            -delete 2>/dev/null || true
    fi
fi

if [[ "$DOMAIN_MODE" == local ]] || [[ "$(printf '%s\n' "$SELECTED_APPS" | wc -w)" -gt 0 ]]; then
    local_generate_ca
fi

while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue
    load_tls_app_config "$app_id" || continue
    tls_mode="${APP_TLS_MODE:-}"
    [[ -n "$tls_mode" ]] || { [[ "$DOMAIN_MODE" == public ]] && tls_mode="acme" || tls_mode="local-ca"; }
    [[ "${APP_CERTIFICATE_ENABLED:-true}" == true ]] || continue
    case "$tls_mode" in
        none) continue ;;
        local-ca)
            cert="${TLS_DIR}/${APP_TLS_NAME:-$app_id}.crt"
            if certificate_needs_regeneration "$cert" "$APP_DOMAIN" "$STATIC_IP"; then
                rm -f "${TLS_DIR}/${APP_TLS_NAME:-$app_id}.key" "$cert"
                local_generate_leaf "${APP_TLS_NAME:-$app_id}" "$APP_DOMAIN" "$STATIC_IP"
            fi
            ;;
        acme) ;;
        *) die "Unsupported TLS mode '$tls_mode' for application '$app_id'." ;;
    esac
done < <(certificate_apps)

if [[ "$DOMAIN_MODE" == local ]]; then
    for entry in "fedora-server:${FEDORA_DOMAIN}:${STATIC_IP}" "proxmox:${PROXMOX_DOMAIN}:${PROXMOX_IP}"; do
        IFS=: read -r name domain ip <<< "$entry"
        cert="${TLS_DIR}/${name}.crt"
        if certificate_needs_regeneration "$cert" "$domain" "$ip"; then
            rm -f "${TLS_DIR}/${name}.key" "$cert"
            local_generate_leaf "$name" "$domain" "$ip"
        fi
    done
    chmod 700 "$TLS_DIR"
    find "$TLS_DIR" -maxdepth 1 -type f -name '*.key' -exec chmod 600 {} +
    find "$TLS_DIR" -maxdepth 1 -type f -name '*.crt' -exec chmod 644 {} +
    log "Local TLS material is ready in ${TLS_DIR}"
    exit 0
fi

dnf install -y python3 python3-pip curl
CERTBOT_VENV="${STACK_DIR}/certbot-venv"
[[ -x "${CERTBOT_VENV}/bin/certbot" ]] || python3 -m venv "$CERTBOT_VENV"
"${CERTBOT_VENV}/bin/python" -m pip install --upgrade pip
"${CERTBOT_VENV}/bin/pip" install --upgrade certbot
CERTBOT="${CERTBOT_VENV}/bin/certbot"
godaddy_credentials_valid || die "GoDaddy PAT is missing. Configure public mode again and provide a valid PAT."
install -m 0750 "${REPO_ROOT}/scripts/godaddy-dns-hook.sh" "${STACK_DIR}/godaddy-dns-hook.sh"
chmod 700 "${STACK_DIR}/godaddy-dns-hook.sh"

zone="${APP_SUBDOMAIN%.}"
zone="${zone#.}"
if [[ -n "$zone" ]]; then zone="${zone}.${BASE_DOMAIN}"; else zone="$BASE_DOMAIN"; fi
cert_name="$zone"
cert_dir="/etc/letsencrypt/live/${cert_name}"
need_public_cert=false
while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue
    load_tls_app_config "$app_id" || continue
    [[ "${APP_CERTIFICATE_ENABLED:-true}" == true ]] || continue
    tls_mode="${APP_TLS_MODE:-acme}"
    [[ "$tls_mode" == acme ]] || continue
    need_public_cert=true
done < <(certificate_apps)

if [[ "$need_public_cert" == true ]]; then
    if [[ -s "${cert_dir}/fullchain.pem" && -s "${cert_dir}/privkey.pem" ]] && openssl x509 -checkend 86400 -noout -in "${cert_dir}/fullchain.pem" >/dev/null 2>&1; then
        log "Wildcard certificate ${cert_name} already exists; renewal is handled by the systemd timer."
    else
        log "Requesting public ACME certificate for ${zone} and *.${zone}"
        email_args=()
        [[ -n "${ACME_EMAIL:-}" ]] && email_args=(--email "$ACME_EMAIL")
        "$CERTBOT" certonly --manual --preferred-challenges dns --manual-auth-hook "${STACK_DIR}/godaddy-dns-hook.sh auth" --manual-cleanup-hook "${STACK_DIR}/godaddy-dns-hook.sh cleanup" --non-interactive --agree-tos "${email_args[@]}" --keep-until-expiring --cert-name "$cert_name" -d "$zone" -d "*.${zone}"
    fi
fi

log "Public TLS material is ready under /etc/letsencrypt/live when required."
