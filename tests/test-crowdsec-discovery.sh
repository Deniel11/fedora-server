#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="${ROOT}/scripts/crowdsec-discovery.awk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "${TMP}/input" <<'EOF_INPUT'
access_log /var/log/nginx/access.log combined;
    access_log /var/log/nginx/$host-access.log main;
access_log "/var/log/nginx/${server_name}/access.log" combined;
access_log '/var/log/nginx/quoted access.log' combined;
access_log off;
access_log syslog:server=127.0.0.1:514;
access_log relative/access.log;
access_log $variable;
EOF_INPUT

awk -f "$PARSER" "${TMP}/input" | sort -u > "${TMP}/actual"
cat > "${TMP}/expected" <<'EOF_EXPECTED'
/var/log/nginx/*-access.log
/var/log/nginx/access.log
/var/log/nginx/quoted access.log
/var/log/nginx/*/access.log
EOF_EXPECTED
sort -u "${TMP}/expected" -o "${TMP}/expected"
diff -u "${TMP}/expected" "${TMP}/actual"

bash -n "${ROOT}/scripts/crowdsec.sh"
[[ $(grep -c 'access_log /var/log/nginx/fedora-server-access.log combined;' "${ROOT}/config/fedora-server.nginx.conf") -eq 2 ]]
[[ $(grep -c 'access_log /var/log/nginx/proxmox-access.log combined;' "${ROOT}/config/proxmox.nginx.conf") -eq 2 ]]
if grep -nE '^[[:space:]]*#[^!]' "${ROOT}/scripts/crowdsec.sh" "${ROOT}/scripts/crowdsec-discovery.awk"; then
    exit 1
fi
printf 'CrowdSec discovery tests passed.\n'
