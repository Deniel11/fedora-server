#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
validate_config
ensure_dirs

[[ -f "$NETWORK_STATE" ]] ||
    die "Network state missing. Run the network stage first."

source "$NETWORK_STATE"

valid_ipv4 "$STATIC_IP" ||
    die "Invalid stored Fedora IP: $STATIC_IP"

[[ -f "$PROXMOX_STATE" ]] ||
    die "Proxmox state missing. Run the Proxmox stage first."

source "$PROXMOX_STATE"

valid_ipv4 "$PROXMOX_IP" ||
    die "Invalid stored Proxmox IP: $PROXMOX_IP"

selection_file="${STATE_DIR}/selected-apps.env"
selected_apps=""

if [[ -f "$selection_file" ]]; then
    source "$selection_file"
    selected_apps="${SELECTED_APPS:-}"
fi

app_list() {
    local app_id
    declare -A seen=()

    for app_id in ${selected_apps}; do
        seen["$app_id"]=1
        printf '%s\n' "$app_id"
    done

    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue
        [[ -n "${seen[$app_id]:-}" ]] && continue
        app_is_installed "$app_id" || continue
        printf '%s\n' "$app_id"
    done < <(app_ids)
}

local_generate_ca() {
    local ca_key="${TLS_DIR}/ca.key"
    local ca_cert="${TLS_DIR}/ca.crt"

    [[ -s "$ca_key" && -s "$ca_cert" ]] && return 0

    log "Generating local Certificate Authority"

    openssl genrsa -out "$ca_key" 4096
    chmod 600 "$ca_key"

    openssl req \
        -x509 \
        -new \
        -sha256 \
        -key "$ca_key" \
        -out "$ca_cert" \
        -days 3650 \
        -subj "/C=XX/O=Home Lab/CN=Home Lab Local CA"

    chmod 644 "$ca_cert"
}

local_generate_leaf() {
    local name="$1"
    local domain="$2"
    local ip="$3"
    local key="${TLS_DIR}/${1}.key"
    local cert="${TLS_DIR}/${1}.crt"
    local csr="${TLS_DIR}/${1}.csr"
    local ext="${TLS_DIR}/${1}.ext"

    cat > "$ext" <<EOF_EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${domain},IP:${ip}
EOF_EXT

    openssl genrsa -out "$key" 2048

    openssl req \
        -new \
        -key "$key" \
        -out "$csr" \
        -subj "/C=XX/O=Home Lab/CN=${domain}"

    openssl x509 \
        -req \
        -in "$csr" \
        -CA "${TLS_DIR}/ca.crt" \
        -CAkey "${TLS_DIR}/ca.key" \
        -CAcreateserial \
        -out "$cert" \
        -days 365 \
        -sha256 \
        -extfile "$ext"

    chmod 600 "$key"
    chmod 644 "$cert"

    rm -f "$csr" "$ext" "${TLS_DIR}/ca.srl"
}

needs_regeneration() {
    local cert="$1"
    local domain="$2"
    local ip="$3"

    [[ -s "$cert" ]] || return 0

    openssl x509 \
        -checkend $((30 * 86400)) \
        -noout \
        -in "$cert" >/dev/null 2>&1 ||
        return 0

    openssl x509 \
        -in "$cert" \
        -noout \
        -ext subjectAltName |
        grep -Fq "DNS:${domain}" ||
        return 0

    openssl x509 \
        -in "$cert" \
        -noout \
        -ext subjectAltName |
        grep -Fq "IP Address:${ip}" ||
        return 0

    return 1
}

if [[ -f "${STATE_DIR}/domain-previous.env" ]]; then
    current_mode="$DOMAIN_MODE"
    current_base="$BASE_DOMAIN"
    current_prefix="$APP_SUBDOMAIN"
    current_email="${ACME_EMAIL:-}"

    source "${STATE_DIR}/domain-previous.env"

    if [[ "${DOMAIN_MODE:-}" == "public" && -n "${BASE_DOMAIN:-}" ]]; then
        old_prefix="${APP_SUBDOMAIN:-home}"
        old_prefix="${old_prefix%.}"
        old_prefix="${old_prefix#.}"

        old_hosts=(
            "fedora-server.${old_prefix}.${BASE_DOMAIN}"
            "proxmox.${old_prefix}.${BASE_DOMAIN}"
            "portainer.${old_prefix}.${BASE_DOMAIN}"
            "vault.${old_prefix}.${BASE_DOMAIN}"
            "joplin.${old_prefix}.${BASE_DOMAIN}"
        )

        for old_domain in "${old_hosts[@]}"; do
            if [[ -x "${STACK_DIR}/certbot-venv/bin/certbot" ]]; then
                "${STACK_DIR}/certbot-venv/bin/certbot" \
                    delete \
                    --cert-name "$old_domain" \
                    --non-interactive >/dev/null 2>&1 || true
            elif command -v certbot >/dev/null 2>&1; then
                certbot \
                    delete \
                    --cert-name "$old_domain" \
                    --non-interactive >/dev/null 2>&1 || true
            fi
        done
    fi

    rm -f "${STATE_DIR}/domain-previous.env"

    DOMAIN_MODE="$current_mode"
    BASE_DOMAIN="$current_base"
    APP_SUBDOMAIN="$current_prefix"
    ACME_EMAIL="$current_email"

    load_config

    DOMAIN_MODE="$current_mode"
    BASE_DOMAIN="$current_base"
    APP_SUBDOMAIN="$current_prefix"
    ACME_EMAIL="$current_email"

    load_domain_state
fi

if [[ "$DOMAIN_MODE" == "local" ]]; then

    CA_KEY="${TLS_DIR}/ca.key"
    CA_CERT="${TLS_DIR}/ca.crt"

    local_generate_ca

    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue

        load_app_config "$app_id" || continue

        [[ "${APP_CERTIFICATE_ENABLED:-true}" == "true" ]] ||
            continue

        cert="${TLS_DIR}/${APP_TLS_NAME}.crt"

        if needs_regeneration "$cert" "$APP_DOMAIN" "$STATIC_IP"; then
            log "Generating/updating local certificate for ${APP_DOMAIN}"

            rm -f \
                "${TLS_DIR}/${APP_TLS_NAME}.key" \
                "$cert"

            local_generate_leaf \
                "$APP_TLS_NAME" \
                "$APP_DOMAIN" \
                "$STATIC_IP"
        fi
    done < <(app_list)

    for item in \
        "fedora-server:${FEDORA_DOMAIN}:${STATIC_IP}" \
        "proxmox:${PROXMOX_DOMAIN}:${PROXMOX_IP}"
    do
        IFS=: read -r name domain ip <<< "$item"

        cert="${TLS_DIR}/${name}.crt"

        if needs_regeneration "$cert" "$domain" "$ip"; then
            log "Generating/updating local certificate for ${domain}"

            rm -f \
                "${TLS_DIR}/${name}.key" \
                "$cert"

            local_generate_leaf \
                "$name" \
                "$domain" \
                "$ip"
        fi
    done

    chmod 700 "$TLS_DIR"
    chmod 600 "$TLS_DIR"/*.key
    chmod 644 "$TLS_DIR"/*.crt

    log "Local TLS material is ready in ${TLS_DIR}"

    exit 0
fi

#
# Public mode:
# Let's Encrypt DNS-01 validation through the GoDaddy v3 DNS API.
#
# The Fedora server does NOT need to be reachable from the Internet.
#

dnf install -y python3 python3-pip curl

CERTBOT_VENV="${STACK_DIR}/certbot-venv"

if [[ ! -x "${CERTBOT_VENV}/bin/certbot" ]]; then
    python3 -m venv "$CERTBOT_VENV"
fi

"${CERTBOT_VENV}/bin/python" \
    -m pip install --upgrade pip

"${CERTBOT_VENV}/bin/pip" \
    install --upgrade certbot

CERTBOT="${CERTBOT_VENV}/bin/certbot"

godaddy_credentials_valid ||
    die "GoDaddy PAT is missing. Run the installer again and configure public-domain credentials."

install \
    -m 0750 \
    "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/godaddy-dns-hook.sh" \
    "${STACK_DIR}/godaddy-dns-hook.sh"

chmod 700 "${STACK_DIR}/godaddy-dns-hook.sh"

mapfile -t CERT_DOMAINS < <(
    printf '%s\n' \
        "$FEDORA_DOMAIN" \
        "$PROXMOX_DOMAIN"

    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue

        load_app_config "$app_id" || continue

        [[ "${APP_CERTIFICATE_ENABLED:-true}" == "true" ]] &&
            printf '%s\n' "$APP_DOMAIN"
    done < <(app_list)
)

for domain in "${CERT_DOMAINS[@]}"; do
    [[ -n "$domain" ]] || continue

    if [[
        -s "/etc/letsencrypt/live/${domain}/fullchain.pem" &&
        -s "/etc/letsencrypt/live/${domain}/privkey.pem"
    ]] &&
        openssl x509 \
            -checkend 86400 \
            -noout \
            -in "/etc/letsencrypt/live/${domain}/fullchain.pem" >/dev/null 2>&1
    then
        log "Public certificate for ${domain} already exists; leaving renewal to the systemd timer."
        continue
    fi

    log "Requesting public ACME DNS-01 certificate for ${domain}"

    email_args=()

    [[ -n "${ACME_EMAIL:-}" ]] &&
        email_args=(--email "$ACME_EMAIL")

    "$CERTBOT" certonly \
        --manual \
        --preferred-challenges dns \
        --manual-auth-hook "${STACK_DIR}/godaddy-dns-hook.sh auth" \
        --manual-cleanup-hook "${STACK_DIR}/godaddy-dns-hook.sh cleanup" \
        --manual-public-ip-logging-ok \
        --non-interactive \
        --agree-tos \
        "${email_args[@]}" \
        --keep-until-expiring \
        -d "$domain"
done

log "Public ACME TLS material is ready under /etc/letsencrypt/live/"