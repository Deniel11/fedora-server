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
printf '%s\n' '# access_log /var/log/nginx/commented.log combined;' >> "${TMP}/input"

awk -f "$PARSER" "${TMP}/input" | sort -u > "${TMP}/actual"
cat > "${TMP}/expected" <<'EOF_EXPECTED'
/var/log/nginx/*-access.log
/var/log/nginx/*/access.log
/var/log/nginx/access.log
/var/log/nginx/quoted access.log
EOF_EXPECTED
sort -u "${TMP}/expected" -o "${TMP}/expected"
diff -u "${TMP}/expected" "${TMP}/actual"
bash -n "${ROOT}/scripts/crowdsec.sh"
grep -Fq "trap 'tx_abort' EXIT" "${ROOT}/scripts/crowdsec.sh"
grep -Fq "CROWDSEC_LOG_TARGETS_SHA256" "${ROOT}/scripts/crowdsec.sh"
grep -Fq "CROWDSEC_NGINX_GROUP_ADDED" "${ROOT}/scripts/crowdsec.sh"
[[ $(grep -c 'CROWDSEC_NGINX_GROUP_ADDED)' "${ROOT}/scripts/crowdsec.sh") -eq 1 ]]
grep -Fq "validate_log_targets_ownership" "${ROOT}/scripts/crowdsec.sh"
grep -Fq "Refusing to overwrite log-target state changed outside this integration." "${ROOT}/scripts/crowdsec.sh"
grep -Fq "Log-target state path is a symbolic link and was retained." "${ROOT}/scripts/crowdsec.sh"
grep -Fq "previous runtime files were restored" "${ROOT}/scripts/crowdsec.sh"
grep -Fq "restore_file_atomically" "${ROOT}/scripts/crowdsec.sh"
grep -Fq "restore_runtime_pair" "${ROOT}/scripts/crowdsec.sh"
grep -Fq 'restore_file_atomically "${source_dir}/previous-script" "$INSTALLED_SCRIPT" || restore_failed=true' "${ROOT}/scripts/crowdsec.sh"
grep -Fq 'restore_file_atomically "${source_dir}/previous-parser" "$INSTALLED_PARSER" || restore_failed=true' "${ROOT}/scripts/crowdsec.sh"
grep -Fq 'disabled) systemctl disable "${SERVICE_NAME}.timer"' "${ROOT}/scripts/crowdsec.sh"
grep -Fq 'not-found|"") ;;' "${ROOT}/scripts/crowdsec.sh"
grep -Fq 'enabled-runtime) systemctl enable --runtime "${SERVICE_NAME}.timer"' "${ROOT}/scripts/crowdsec.sh"
grep -Fq 'root:750 ]]' "${ROOT}/scripts/crowdsec.sh"
grep -Fq 'linked|linked-runtime) ;;' "${ROOT}/scripts/crowdsec.sh"
grep -Fq 'TX_LINK_TARGETS' "${ROOT}/scripts/crowdsec.sh"
grep -Fq 'tx_snapshot "$RUNTIME_TIMER_FILE"' "${ROOT}/scripts/crowdsec.sh"
grep -Fq "Rollback was incomplete. Recovery files were retained at:" "${ROOT}/scripts/crowdsec.sh"
grep -Fq "TX_RESTORE_FAILED" "${ROOT}/scripts/crowdsec.sh"
grep -Fq "trap 'tx_abort' EXIT" "${ROOT}/scripts/crowdsec.sh"
[[ $(grep -c '^restore_file_atomically()' "${ROOT}/scripts/crowdsec.sh") -eq 1 ]]
[[ $(grep -c '^tx_restore()' "${ROOT}/scripts/crowdsec.sh") -eq 1 ]]
grep -Fq -- "--sync-runtime" "${ROOT}/update-repo.sh"
grep -Fq "CrowdSec integration cleanup failed" "${ROOT}/install.sh"
[[ $(grep -c 'access_log /var/log/nginx/fedora-server-access.log combined;' "${ROOT}/config/fedora-server.nginx.conf") -eq 2 ]]
[[ $(grep -c 'access_log /var/log/nginx/proxmox-access.log combined;' "${ROOT}/config/proxmox.nginx.conf") -eq 2 ]]
if grep -nE '^[[:space:]]*#[^!]' "${ROOT}/scripts/crowdsec.sh" "${ROOT}/scripts/crowdsec-discovery.awk"; then
    exit 1
fi
printf 'CrowdSec discovery tests passed.\n'
