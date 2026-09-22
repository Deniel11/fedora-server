#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/Deniel11/fedora-server"
ARCHIVE_URL="${REPO_URL}/archive/refs/heads/main.tar.gz"

INSTALL_DIR="/opt/fedora-server-setup"

TMP_ARCHIVE="/tmp/fedora-server-bootstrap.tar.gz"
TMP_ROOT="/tmp/fedora-server-bootstrap"
TMP_REPO="${TMP_ROOT}/fedora-server-main"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: this script must be run as root." >&2
    echo "Usage: sudo ./bootstrap.sh" >&2
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

cleanup() {
    rm -rf "$TMP_ROOT"
    rm -f "$TMP_ARCHIVE"
}

trap cleanup EXIT

echo "==> Downloading Fedora Server Home Services Setup..."

rm -rf "$TMP_ROOT"
rm -f "$TMP_ARCHIVE"

mkdir -p "$TMP_ROOT"

curl -fL --retry 3 --retry-delay 2 \
    -o "$TMP_ARCHIVE" \
    "$ARCHIVE_URL"

tar -xzf "$TMP_ARCHIVE" -C "$TMP_ROOT"

if [[ ! -d "$TMP_REPO" ]]; then
    echo "Error: downloaded repository directory was not found." >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"

echo "==> Installing repository files to $INSTALL_DIR..."

cp -a "$TMP_REPO"/. "$INSTALL_DIR"/

chmod +x \
    "$INSTALL_DIR/bootstrap.sh" \
    "$INSTALL_DIR/update-repo.sh" \
    "$INSTALL_DIR/install.sh"

echo
echo "========================================"
echo " Bootstrap completed"
echo "========================================"
echo
echo "Repository:"
echo "  $INSTALL_DIR"
echo
echo "Run the main installer with:"
echo "  sudo $INSTALL_DIR/install.sh"
echo
echo "For future repository updates:"
echo "  sudo $INSTALL_DIR/update-repo.sh"