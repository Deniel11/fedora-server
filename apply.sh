#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

[[ -f install.sh && -f scripts/00-common.sh && -f scripts/public-access.sh && -f config/domains.conf ]] || {
    printf '%s\n' "Run this script from the root of the fedora-server repository." >&2
    exit 1
}

python3 - <<'PY'
from pathlib import Path

root = Path.cwd()
changes = {}

def plan(path, replacements):
    p = root / path
    if not p.is_file():
        raise SystemExit(f"Required file not found: {path}")
    original = p.read_text(encoding="utf-8")
    updated = original
    for old, new, count in replacements:
        found = updated.count(old)
        if found != count:
            raise SystemExit(f"Expected {count} occurrence(s) of anchor in {path}, found {found}. No files have been changed.")
        updated = updated.replace(old, new, count)
    changes[p] = updated

plan("config/domains.conf", [
    ('GOACCESS_PORT="7891"', 'GOACCESS_PORT="7891"\n\nGRAFANA_DOMAIN="grafana.home"\nGRAFANA_PORT="3001"\nLOKI_PORT="3100"\nLOKI_RETENTION_PERIOD="30d"', 1),
])

plan("scripts/00-common.sh", [
    ('            FORGEJO_DOMAIN="forgejo.${prefix}.${BASE_DOMAIN}"\n', '            FORGEJO_DOMAIN="forgejo.${prefix}.${BASE_DOMAIN}"\n            GRAFANA_DOMAIN="grafana.${prefix}.${BASE_DOMAIN}"\n', 1),
    ('            FORGEJO_DOMAIN="forgejo.${BASE_DOMAIN}"\n', '            FORGEJO_DOMAIN="forgejo.${BASE_DOMAIN}"\n            GRAFANA_DOMAIN="grafana.${BASE_DOMAIN}"\n', 1),
    ('        APP_NAME \\\n', '        APP_NAME \\\n        APP_DESCRIPTION \\\n', 1),
    ('        APP_HEALTHCHECK_URL\n', '        APP_HEALTHCHECK_URL \\\n        APP_PUBLIC_ACCESS_ALLOWED \\\n        APP_CONFIG_EXTRA_SIGNATURE \\\n        APP_DATA_DIR\n', 1),
    ("    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \\\n", "    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \\\n", 1),
    ('        "${APP_DOMAIN_ALIASES:-}"\n', '        "${APP_DOMAIN_ALIASES:-}" \\\n        "${APP_PUBLIC_ACCESS_ALLOWED:-true}" \\\n        "${APP_CONFIG_EXTRA_SIGNATURE:-}"\n', 1),
    ('    if [[ "${DOMAIN_MODE:-local}" == "public" ]]; then\n        load_public_access_state\n', '    if [[ "${DOMAIN_MODE:-local}" == "public" || "${APP_PUBLIC_ACCESS_ALLOWED:-true}" == "false" ]]; then\n        load_public_access_state\n', 1),
    ('        if is_public_app "$app_id"; then\n', '        if [[ "${APP_PUBLIC_ACCESS_ALLOWED:-true}" != "false" ]] && is_public_app "$app_id"; then\n', 1),
])

plan("scripts/public-access.sh", [
    ('        [[ "${APP_NGINX_ENABLED:-true}" == "true" ]] || continue\n        if [[ "$force" != true && " ${configured} " == *" ${app_id} "* ]]; then\n', '''        [[ "${APP_NGINX_ENABLED:-true}" == "true" ]] || continue
        if [[ "${APP_PUBLIC_ACCESS_ALLOWED:-true}" == "false" ]]; then
            kept=""
            for item in $public; do
                [[ "$item" == "$app_id" ]] && continue
                kept+="${kept:+ }${item}"
            done
            public="$kept"
            [[ " ${configured} " == *" ${app_id} "* ]] || configured+="${configured:+ }${app_id}"
            continue
        fi
        if [[ "$force" != true && " ${configured} " == *" ${app_id} "* ]]; then
''', 1),
])

plan("install.sh", [
    ('''            printf '  - %s (%s, host port %s)\\n' \\
                "$APP_NAME" \\
                "$APP_ID" \\
                "${APP_PORT:-not set}"
''', '''            printf '  - %s (%s, host port %s)\\n    %s\\n' \\
                "$APP_NAME" \\
                "$APP_ID" \\
                "${APP_PORT:-not set}" \\
                "${APP_DESCRIPTION:-No description available.}"
''', 1),
    ('''                printf '  - %s (%s -> port %s)\\n' \\
                    "$APP_NAME" \\
                    "$APP_DOMAIN" \\
                    "${APP_PORT:-not set}"
''', '''                printf '  - %s (%s -> port %s)\\n    %s\\n' \\
                    "$APP_NAME" \\
                    "$APP_DOMAIN" \\
                    "${APP_PORT:-not set}" \\
                    "${APP_DESCRIPTION:-No description available.}"
''', 1),
    ('''        read -r -p \\
            "Install/update ${APP_NAME} (${APP_DOMAIN}, host port ${APP_PORT})? [y/N]: " \\
            answer
''', '''        read -r -p \\
            "Install/update ${APP_NAME} (${APP_DOMAIN}, host port ${APP_PORT}) — ${APP_DESCRIPTION:-No description available.} [y/N]: " \\
            answer
''', 1),
    ('''        printf '  %d) %s (%s, host port %s)\\n' \\
            "$((item + 1))" \\
            "$APP_NAME" \\
            "$APP_ID" \\
            "${APP_PORT:-not set}"
''', '''        printf '  %d) %s (%s, host port %s)\\n     %s\\n' \\
            "$((item + 1))" \\
            "$APP_NAME" \\
            "$APP_ID" \\
            "${APP_PORT:-not set}" \\
            "${APP_DESCRIPTION:-No description available.}"
''', 1),
    ('''        printf '  - %s (%s -> port %s)\\n' \\
            "$APP_NAME" \\
            "$APP_DOMAIN" \\
            "${APP_PORT:-not set}"
''', '''        printf '  - %s (%s -> port %s)\\n    %s\\n' \\
            "$APP_NAME" \\
            "$APP_DOMAIN" \\
            "${APP_PORT:-not set}" \\
            "${APP_DESCRIPTION:-No description available.}"
''', 1),
    ('''    rm -rf "$runtime"

    app_nginx_remove "$app_id"
''', '''    if [[ "$data_answer" =~ ^[Yy]$ && "${APP_DATA_DIR:-}" == /opt/fedora-server-data/* ]]; then
        rm -rf -- "$APP_DATA_DIR"
    fi

    rm -rf "$runtime"

    app_nginx_remove "$app_id"
''', 1),
    ('''        rm -rf "$runtime"
    done < <(app_ids)
''', '''        if [[ "$data_answer" =~ ^[Yy]$ && "${APP_DATA_DIR:-}" == /opt/fedora-server-data/* ]]; then
            rm -rf -- "$APP_DATA_DIR"
        fi

        rm -rf "$runtime"
    done < <(app_ids)
''', 1),
])

description_map = {
    "forgejo": "Git repository hosting and collaboration.",
    "goaccess": "Real-time web analytics for Nginx access logs.",
    "joplin": "Joplin Server for synchronizing notes.",
    "portainer": "Web interface for managing Docker containers.",
    "vaultwarden": "Self-hosted Bitwarden-compatible password manager.",
}
for app_id, description in description_map.items():
    path = root / "apps" / app_id / "app.conf"
    if not path.is_file():
        raise SystemExit(f"Required file not found: {path.relative_to(root)}")
    text = path.read_text(encoding="utf-8")
    if "APP_DESCRIPTION=" in text:
        continue
    marker = next((line for line in text.splitlines(keepends=True) if line.startswith("APP_NAME=")), None)
    if marker is None:
        raise SystemExit(f"APP_NAME anchor not found in {path.relative_to(root)}. No files have been changed.")
    changes[path] = text.replace(marker, marker + f'APP_DESCRIPTION="{description}"\n', 1)

app_source = root / "apps" / "loki-grafana"
if not app_source.is_dir():
    raise SystemExit("apps/loki-grafana was not found. Extract the bundle contents into the repository root first.")

for path, content in changes.items():
    path.write_text(content, encoding="utf-8", newline="\n")

print("Existing files updated. The Loki + Grafana module files are in apps/loki-grafana.")
PY

bash -n install.sh
bash -n scripts/00-common.sh
bash -n scripts/public-access.sh
bash -n apps/loki-grafana/*.sh
git diff --check
printf '%s\n' "Patch applied. Review with: git diff --stat && git diff"
