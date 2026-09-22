#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/Deniel11/fedora-server"
ARCHIVE_URL="${REPO_URL}/archive/refs/heads/main.tar.gz"
INSTALL_DIR="/opt/fedora-server-setup"
TMP_ARCHIVE="/tmp/fedora-server-update.tar.gz"
TMP_ROOT="/tmp/fedora-server-update"
TMP_REPO="${TMP_ROOT}/fedora-server-main"
TMP_CONFIG="${TMP_ROOT}/domains.conf.local"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: this script must be run as root." >&2
    echo "Usage: sudo ${INSTALL_DIR}/update-repo.sh" >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "Error: curl is required." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "Error: tar is required." >&2; exit 1; }

[[ -d "$INSTALL_DIR" ]] || { echo "Error: installation directory does not exist: $INSTALL_DIR" >&2; exit 1; }

cleanup() {
    rm -rf "$TMP_ROOT"
    rm -f "$TMP_ARCHIVE"
}
trap cleanup EXIT

rm -rf "$TMP_ROOT"
rm -f "$TMP_ARCHIVE"
mkdir -p "$TMP_ROOT"

echo "========================================"
echo " Fedora Server - Repository Update"
echo "========================================"
echo

echo "[1/3] Downloading the latest repository..."
curl -fL --retry 3 --retry-delay 2 -o "$TMP_ARCHIVE" "$ARCHIVE_URL"

echo "[2/3] Extracting the repository..."
tar -xzf "$TMP_ARCHIVE" -C "$TMP_ROOT"
[[ -d "$TMP_REPO" ]] || { echo "Error: downloaded repository directory was not found." >&2; exit 1; }

echo "[3/3] Updating repository files..."

# Preserve the operator's local domain/port configuration across repository updates.
if [[ -f "${INSTALL_DIR}/config/domains.conf" ]]; then
    cp "${INSTALL_DIR}/config/domains.conf" "$TMP_CONFIG"
fi

cp -a "$TMP_REPO"/. "$INSTALL_DIR"/

if [[ -f "$TMP_CONFIG" ]]; then
    cp "$TMP_CONFIG" "${INSTALL_DIR}/config/domains.conf"
fi

find "$INSTALL_DIR" -type f -name '*.sh' -exec chmod +x {} +

echo
echo "========================================"
echo " Repository update completed"
echo "========================================"
echo
echo "Repository: $INSTALL_DIR"
echo "Runtime data remains outside the repository."
echo
echo "Run the installer after an update when required:"
echo "  sudo $INSTALL_DIR/install.sh"
