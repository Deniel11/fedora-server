#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
validate_config
ensure_dirs

[[ -f "$NETWORK_STATE" ]] || die "Network state missing. Run the network stage first."
# shellcheck disable=SC1090
source "$NETWORK_STATE"
valid_ipv4 "$STATIC_IP" || die "Invalid stored Fedora IP: $STATIC_IP"

[[ -f "$PROXMOX_STATE" ]] || die "Proxmox state missing. Run the Proxmox stage first."
# shellcheck disable=SC1090
source "$PROXMOX_STATE"
valid_ipv4 "$PROXMOX_IP" || die "Invalid stored Proxmox IP: $PROXMOX_IP"

CA_KEY="${TLS_DIR}/ca.key"
CA_CERT="${TLS_DIR}/ca.crt"

selection_file="${STATE_DIR}/selected-apps.env"
selected_apps=""
if [[ -f "$selection_file" ]]; then
    # shellcheck disable=SC1090
    source "$selection_file"
    selected_apps="${SELECTED_APPS:-}"
fi

app_list() {
    local app_id
    declare -A seen=()
    for app_id in ${selected_apps}; do
        seen["$app_id"]=1
        printf '%s
' "$app_id"
    done
    while IFS= read -r app_id; do
        [[ -n "$app_id" ]] || continue
        [[ -n "${seen[$app_id]:-}" ]] && continue
        app_is_installed "$app_id" || continue
        printf '%s
' "$app_id"
    done < <(app_ids)
}

generate_ca() {
    log "Generating local Certificate Authority"
    openssl genrsa -out "$CA_KEY" 4096
    chmod 600 "$CA_KEY"
    openssl req -x509 -new -sha256 -key "$CA_KEY" -out "$CA_CERT" \
        -days 3650 -subj "/C=XX/O=Home Lab/CN=Home Lab Local CA"
    chmod 644 "$CA_CERT"
}

[[ -s "$CA_KEY" && -s "$CA_CERT" ]] || generate_ca

generate_leaf() {
    local name="$1" domain="$2" ip="$3"
    local key="${TLS_DIR}/${name}.key"
    local cert="${TLS_DIR}/${name}.crt"
    local csr="${TLS_DIR}/${name}.csr"
    local ext="${TLS_DIR}/${name}.ext"

    cat > "$ext" <<EOF_EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${domain},IP:${ip}
EOF_EXT

    openssl genrsa -out "$key" 2048
    openssl req -new -key "$key" -out "$csr" \
        -subj "/C=XX/O=Home Lab/CN=${domain}"
    openssl x509 -req -in "$csr" -CA "$CA_CERT" -CAkey "$CA_KEY" \
        -CAcreateserial -out "$cert" -days 365 -sha256 -extfile "$ext"

    chmod 600 "$key"
    chmod 644 "$cert"
    rm -f "$csr" "$ext" "${TLS_DIR}/ca.srl"
}

needs_regeneration() {
    local cert="$1" domain="$2" ip="$3"
    [[ -s "$cert" ]] || return 0
    openssl x509 -checkend $((30*86400)) -noout -in "$cert" >/dev/null 2>&1 || return 0
    openssl x509 -in "$cert" -noout -ext subjectAltName | grep -Fq "DNS:${domain}" || return 0
    openssl x509 -in "$cert" -noout -ext subjectAltName | grep -Fq "IP Address:${ip}" || return 0
    return 1
}

for app_id in $(app_list); do
    load_app_config "$app_id" || continue
    [[ "${APP_CERTIFICATE_ENABLED:-true}" == "true" ]] || continue
    domain="$APP_DOMAIN"
    name="$APP_TLS_NAME"
    cert="${TLS_DIR}/${name}.crt"
    key="${TLS_DIR}/${name}.key"

    if needs_regeneration "$cert" "$domain" "$STATIC_IP"; then
        log "Generating/updating certificate for ${domain}"
        rm -f "$key" "$cert"
        generate_leaf "$name" "$domain" "$STATIC_IP"
    else
        log "Certificate for ${domain} is current; skipping regeneration."
    fi
done

# Proxmox is external infrastructure, but its HTTPS endpoint is published
# through the Fedora Nginx reverse proxy.
if needs_regeneration "${TLS_DIR}/proxmox.crt" "$PROXMOX_DOMAIN" "$PROXMOX_IP"; then
    log "Generating/updating certificate for ${PROXMOX_DOMAIN}"
    rm -f "${TLS_DIR}/proxmox.key" "${TLS_DIR}/proxmox.crt"
    generate_leaf "proxmox" "$PROXMOX_DOMAIN" "$PROXMOX_IP"
else
    log "Certificate for ${PROXMOX_DOMAIN} is current; skipping regeneration."
fi

# Cockpit is part of Fedora infrastructure, not a Docker application.
# It uses its own generated certificate and remains available independently.
if [[ -s "${TLS_DIR}/fedora-server.crt" && -s "${TLS_DIR}/fedora-server.key" ]]; then
    log "Cockpit certificate is already available."
elif needs_regeneration "${TLS_DIR}/fedora-server.crt" "$FEDORA_DOMAIN" "$STATIC_IP"; then
    generate_leaf "fedora-server" "$FEDORA_DOMAIN" "$STATIC_IP"
fi

chmod 700 "$TLS_DIR"
chmod 600 "$CA_KEY" "${TLS_DIR}"/*.key
chmod 644 "$CA_CERT" "${TLS_DIR}"/*.crt

log "TLS material is ready in ${TLS_DIR}"
