#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
ensure_dirs

command -v nmcli >/dev/null 2>&1 || die "NetworkManager/nmcli is not available."

mapfile -t active_connections < <(
    nmcli -t -f NAME,DEVICE,TYPE connection show --active |
    awk -F: '$3=="802-3-ethernet" || $3=="wifi" {print $1 "|" $2}'
)

if ((${#active_connections[@]} == 0)); then
    die "No active Ethernet/Wi-Fi NetworkManager connection found."
fi

echo
echo "Active NetworkManager connections:"
for i in "${!active_connections[@]}"; do
    printf '  [%d] %s\n' "$((i+1))" "${active_connections[$i]}"
done

default_choice=1
if [[ -f "$NETWORK_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$NETWORK_STATE"
    for i in "${!active_connections[@]}"; do
        if [[ "${active_connections[$i]%%|*}" == "${CONNECTION_NAME:-}" ]]; then
            default_choice=$((i+1))
            break
        fi
    done
fi

read -r -p "Connection number [${default_choice}]: " choice
choice="${choice:-$default_choice}"
[[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#active_connections[@]})) ||
    die "Invalid connection selection."

selected="${active_connections[$((choice-1))]}"
CONNECTION_NAME="${selected%%|*}"
INTERFACE="${selected#*|}"

current_ip="$(nmcli -g IP4.ADDRESS device show "$INTERFACE" | head -n1 | cut -d/ -f1 || true)"
current_prefix="$(nmcli -g IP4.ADDRESS device show "$INTERFACE" | head -n1 | cut -d/ -f2 || true)"
current_gateway="$(nmcli -g IP4.GATEWAY device show "$INTERFACE" | head -n1 || true)"
current_dns="$(nmcli -g IP4.DNS device show "$INTERFACE" | head -n1 || true)"

echo
warn "Changing the network configuration may disconnect an SSH session."
warn "If you are connected remotely, make sure you can reconnect using the new IP."
echo

echo
echo "Current network configuration:"
echo "  Connection : $CONNECTION_NAME"
echo "  Interface  : $INTERFACE"
echo "  IPv4       : ${current_ip:-not set}/${current_prefix:-?}"
echo "  Gateway    : ${current_gateway:-not set}"
echo "  DNS        : ${current_dns:-not set}"
echo

read -r -p "Is the current network configuration OK? [Y/n]: " keep_current
keep_current="${keep_current:-Y}"

if [[ "$keep_current" =~ ^[Yy]$ ]]; then
    STATIC_IP="$current_ip"
    PREFIX="$current_prefix"
    GATEWAY="$current_gateway"
    DNS_SERVER="$current_dns"

    [[ -n "$STATIC_IP" ]] || die "Current IPv4 address is not available."
    [[ -n "$PREFIX" ]] || die "Current prefix length is not available."
    [[ -n "$GATEWAY" ]] || die "Current gateway is not available."
    [[ -n "$DNS_SERVER" ]] || die "Current DNS server is not available."

    log "Keeping the current network configuration."
else
    echo
    read -r -p "Static IPv4 [${current_ip:-192.168.1.50}]: " STATIC_IP
    STATIC_IP="${STATIC_IP:-${current_ip:-192.168.1.50}}"
    valid_ipv4 "$STATIC_IP" || die "Invalid IPv4 address."

    read -r -p "Prefix length [${current_prefix:-24}]: " PREFIX
    PREFIX="${PREFIX:-${current_prefix:-24}}"
    valid_prefix "$PREFIX" || die "Invalid prefix length."

    read -r -p "Gateway [${current_gateway:-192.168.1.1}]: " GATEWAY
    GATEWAY="${GATEWAY:-${current_gateway:-192.168.1.1}}"
    valid_ipv4 "$GATEWAY" || die "Invalid gateway IPv4 address."

    read -r -p "DNS server [${current_dns:-1.1.1.1}]: " DNS_SERVER
    DNS_SERVER="${DNS_SERVER:-${current_dns:-1.1.1.1}}"
    valid_ipv4 "$DNS_SERVER" || die "Invalid DNS server IPv4 address."
fi
echo
echo "Selected configuration:"
echo "  Connection : $CONNECTION_NAME"
echo "  Interface  : $INTERFACE"
echo "  IPv4       : $STATIC_IP/$PREFIX"
echo "  Gateway    : $GATEWAY"
echo "  DNS        : $DNS_SERVER"
echo

read -r -p "Apply this configuration? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || die "Network configuration cancelled."

nmcli connection modify "$CONNECTION_NAME" \
    ipv4.method manual \
    ipv4.addresses "${STATIC_IP}/${PREFIX}" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DNS_SERVER"

nmcli connection up "$CONNECTION_NAME"

sleep 2

ip -4 addr show dev "$INTERFACE" | grep -q "inet ${STATIC_IP}/" ||
    die "Network connection came up, but ${STATIC_IP}/${PREFIX} was not detected."

cat > "$NETWORK_STATE" <<EOF
CONNECTION_NAME=$(printf '%q' "$CONNECTION_NAME")
INTERFACE=$(printf '%q' "$INTERFACE")
STATIC_IP=$(printf '%q' "$STATIC_IP")
PREFIX=$(printf '%q' "$PREFIX")
GATEWAY=$(printf '%q' "$GATEWAY")
DNS_SERVER=$(printf '%q' "$DNS_SERVER")
EOF
chmod 600 "$NETWORK_STATE"

log "Static network configuration applied."
