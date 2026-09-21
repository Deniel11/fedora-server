#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
ensure_dirs

[[ -f "$NETWORK_STATE" ]] || die "Network state missing. Run 02-network.sh first."
# shellcheck disable=SC1090
source "$NETWORK_STATE"

valid_ipv4 "$STATIC_IP" || die "Invalid stored Fedora IP: $STATIC_IP"
for domain in "$FEDORA_DOMAIN" "$PORTAINER_DOMAIN" "$VAULTWARDEN_DOMAIN" "$PROXMOX_DOMAIN"; do
    valid_hostname "$domain" || die "Invalid hostname in config: $domain"
done

CA_KEY="${TLS_DIR}/ca.key"
CA_CERT="${TLS_DIR}/ca.crt"

generate_ca() {
    log "Generating local Certificate Authority"
    openssl genrsa -out "$CA_KEY" 4096
    chmod 600 "$CA_KEY"
    openssl req -x509 -new -sha256 \
        -key "$CA_KEY" \
        -out "$CA_CERT" \
        -days 3650 \
        -subj "/C=XX/O=Home Lab/CN=Home Lab Local CA"
    chmod 644 "$CA_CERT"
}

[[ -s "$CA_KEY" && -s "$CA_CERT" ]] || generate_ca

generate_leaf() {
    local name="$1"
    local domain="$2"
    local ip="$3"
    local key="${TLS_DIR}/${name}.key"
    local cert="${TLS_DIR}/${name}.crt"
    local csr="${TLS_DIR}/${name}.csr"
    local ext="${TLS_DIR}/${name}.ext"

    cat > "$ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${domain},IP:${ip}
EOF

    openssl genrsa -out "$key" 2048

    openssl req -new \
        -key "$key" \
        -out "$csr" \
        -subj "/C=XX/O=Home Lab/CN=${domain}"

    openssl x509 -req \
        -in "$csr" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
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
    local cert="$1" domain="$2" ip="$3"
    [[ -s "$cert" ]] || return 0
    openssl x509 -checkend $((30*86400)) -noout -in "$cert" >/dev/null 2>&1 || return 0
    openssl x509 -in "$cert" -noout -ext subjectAltName |
        grep -Fq "DNS:${domain}" || return 0
    openssl x509 -in "$cert" -noout -ext subjectAltName |
        grep -Fq "IP Address:${ip}" || return 0
    return 1
}

for spec in \
    "fedora-server:${FEDORA_DOMAIN}" \
    "portainer:${PORTAINER_DOMAIN}" \
    "vaultwarden:${VAULTWARDEN_DOMAIN}"
do
    name="${spec%%:*}"
    domain="${spec#*:}"
    cert="${TLS_DIR}/${name}.crt"
    key="${TLS_DIR}/${name}.key"

    if needs_regeneration "$cert" "$domain" "$STATIC_IP"; then
        log "Generating/updating certificate for ${domain}"
        rm -f "$key" "$cert"
        generate_leaf "$name" "$domain" "$STATIC_IP"
    fi
done

chmod 700 "$TLS_DIR"
chmod 600 "$CA_KEY" "${TLS_DIR}"/*.key
chmod 644 "$CA_CERT" "${TLS_DIR}"/*.crt

log "TLS material is ready in ${TLS_DIR}"
