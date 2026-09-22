#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/Deniel11/fedora-server"
ARCHIVE_URL="${REPO_URL}/archive/refs/heads/main.tar.gz"

INSTALL_DIR="/opt/fedora-server-setup"

TMP_ARCHIVE="/tmp/fedora-server-update.tar.gz"
TMP_ROOT="/tmp/fedora-server-update"
TMP_REPO="${TMP_ROOT}/fedora-server-main"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: this script must be run as root." >&2
    echo "Usage: sudo ${INSTALL_DIR}/update-repo.sh" >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || {
    echo "Error: curl is required." >&2
    exit 1
}

command -v tar >/dev/null 2>&1 || {
    echo "Error: tar is required." >&2
    exit 1
}

if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Error: installation directory does not exist:" >&2
    echo "  $INSTALL_DIR" >&2
    echo >&2
    echo "Run bootstrap.sh first." >&2
    exit 1
fi

cleanup() {
    rm -rf "$TMP_ROOT"
    rm -f "$TMP_ARCHIVE"
}

trap cleanup EXIT

echo "========================================"
echo " Fedora Server - Repository Update"
echo "========================================"

echo
echo "[1/4] Preparing temporary files..."

rm -rf "$TMP_ROOT"
rm -f "$TMP_ARCHIVE"

mkdir -p "$TMP_ROOT"

echo "[2/4] Downloading the latest repository..."

curl -fL --retry 3 --retry-delay 2 \
    -o "$TMP_ARCHIVE" \
    "$ARCHIVE_URL"

echo "[3/4] Extracting the repository..."

tar -xzf "$TMP_ARCHIVE" -C "$TMP_ROOT"

if [[ ! -d "$TMP_REPO" ]]; then
    echo "Error: downloaded repository directory was not found." >&2
    exit 1
fi

echo "[4/4] Updating repository files..."

cp -a "$TMP_REPO"/. "$INSTALL_DIR"/

chmod +x \
    "$INSTALL_DIR/bootstrap.sh" \
    "$INSTALL_DIR/update-repo.sh" \
    "$INSTALL_DIR/install.sh"

echo
echo "========================================"
echo " Repository update completed"
echo "========================================"
echo
echo "Repository:"
echo "  $INSTALL_DIR"
echo
echo "Runtime data and configuration outside"
echo "the repository are left untouched."
echo
echo "If the installation scripts changed, run:"
echo "  sudo $INSTALL_DIR/install.sh"