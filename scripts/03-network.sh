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

((${#active_connections[@]} > 0)) || die "No active Ethernet/Wi-Fi NetworkManager connection found."

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
[[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#active_connections[@]})) || die "Invalid connection selection."

selected="${active_connections[$((choice-1))]}"
CONNECTION_NAME="${selected%%|*}"
INTERFACE="${selected#*|}"

current_ip="$(nmcli -g IP4.ADDRESS device show "$INTERFACE" | head -n1 | cut -d/ -f1 || true)"
current_prefix="$(nmcli -g IP4.ADDRESS device show "$INTERFACE" | head -n1 | cut -d/ -f2 || true)"
current_gateway="$(nmcli -g IP4.GATEWAY device show "$INTERFACE" | head -n1 || true)"
current_dns="$(nmcli -g IP4.DNS device show "$INTERFACE" | head -n1 || true)"

echo
echo "Current network configuration:"
echo "  Connection : $CONNECTION_NAME"
echo "  Interface  : $INTERFACE"
echo "  IPv4       : ${current_ip:-not set}/${current_prefix:-?}"
echo "  Gateway    : ${current_gateway:-not set}"
echo "  DNS        : ${current_dns:-not set}"

if [[ -f "$NETWORK_STATE" && -n "$current_ip" && -n "$current_prefix" && -n "$current_gateway" && -n "$current_dns" ]]; then
    # shellcheck disable=SC1090
    source "$NETWORK_STATE"
    if [[ "${CONNECTION_NAME:-}" == "${selected%%|*}" &&
          "${INTERFACE:-}" == "${selected#*|}" &&
          "${STATIC_IP:-}" == "$current_ip" &&
          "${PREFIX:-}" == "$current_prefix" &&
          "${GATEWAY:-}" == "$current_gateway" &&
          "${DNS_SERVER:-}" == "$current_dns" ]]; then
        log "Current network configuration already matches saved state; no network change required."
        exit 0
    fi
    CONNECTION_NAME="${selected%%|*}"
    INTERFACE="${selected#*|}"
fi

echo
warn "The next operation may interrupt the current network/session connection."
warn "If you are connected remotely through SSH or Cockpit, that session may disconnect."
warn "After reconnecting, run: sudo ${STACK_DIR}/install.sh"
read -r -p "Continue with this operation? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || die "Network operation cancelled."

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

echo
echo "Selected configuration:"
printf '  Connection : %s\n  Interface  : %s\n  IPv4       : %s/%s\n  Gateway    : %s\n  DNS        : %s\n' \
    "$CONNECTION_NAME" "$INTERFACE" "$STATIC_IP" "$PREFIX" "$GATEWAY" "$DNS_SERVER"

read -r -p "Apply this configuration? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || die "Network configuration cancelled."

cat > "$NETWORK_STATE" <<EOF_STATE
CONNECTION_NAME=$(printf '%q' "$CONNECTION_NAME")
INTERFACE=$(printf '%q' "$INTERFACE")
STATIC_IP=$(printf '%q' "$STATIC_IP")
PREFIX=$(printf '%q' "$PREFIX")
GATEWAY=$(printf '%q' "$GATEWAY")
DNS_SERVER=$(printf '%q' "$DNS_SERVER")
EOF_STATE
chmod 600 "$NETWORK_STATE"

nmcli connection modify "$CONNECTION_NAME" \
    ipv4.method manual \
    ipv4.addresses "${STATIC_IP}/${PREFIX}" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DNS_SERVER"

warn "Applying the network profile now. Your current session may disconnect."
nmcli connection up "$CONNECTION_NAME" || {
    warn "NetworkManager did not immediately report success."
    warn "Wait approximately 10 seconds, reconnect, then run sudo ${STACK_DIR}/install.sh"
    exit 0
}

sleep 2

if ip -4 addr show dev "$INTERFACE" | grep -q "inet ${STATIC_IP}/"; then
    log "Static network configuration applied successfully."
else
    warn "The connection came up, but ${STATIC_IP}/${PREFIX} was not detected yet."
fi

echo
echo "========================================"
echo " Network change completed"
echo "========================================"
echo "Your current SSH/Cockpit session may disconnect."
echo "Wait about 10 seconds, reconnect to the new IP, then run:"
echo
echo "  sudo ${STACK_DIR}/install.sh"
echo
echo "The installer will detect the completed network stage and continue."
echo
sleep 10
exit 20
