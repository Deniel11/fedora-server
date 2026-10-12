#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# The wizard now exposes its generation functions when sourced.
source "${SCRIPT_DIR}/custom-app-wizard.sh"

refreshed=0
skipped=0

echo
echo "========================================"
echo " Refresh generated custom applications"
echo "========================================"
echo
echo "This refreshes generated install, verify, remove and Nginx template files."
echo "It preserves each application's app.conf."
echo "It does not deploy or restart applications."
echo

while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue

    if ! load_app_config "$app_id"; then
        continue
    fi

    [[ "${APP_TYPE:-}" == "custom" ]] || continue

    app_definition_dir="$(app_dir "$app_id")"
    runtime="$(app_runtime_dir "$app_id")"
    pending_dir="${runtime}/source-pending"
    source_dir="${runtime}/source"
    legacy_source_dir="/opt/fedora-server-sources/${app_id}/unpacked"

    echo
    echo "Refreshing: ${APP_NAME} (${app_id})"

    install -d -m 0750 "$runtime"

    # The modern installer expects source or source-pending under its runtime
    # directory. Migrate an older extracted source tree when one exists.
    if [[ ! -d "$source_dir" && ! -d "$pending_dir" ]]; then
        if [[ -d "$legacy_source_dir" ]]; then
            install -d -m 0750 "$pending_dir"
            cp -a "${legacy_source_dir}/." "$pending_dir/"
            echo "Migrated the existing source into source-pending."
        else
            if [[ -z "${APP_SOURCE_URL:-}" ||
                  -z "${APP_SOURCE_REF:-}" ]]; then
                warn "No source URL/ref is configured for ${app_id}; skipping."
                skipped=$((skipped + 1))
                continue
            fi

            archive="$(archive_url_for "$APP_SOURCE_URL" "$APP_SOURCE_REF")"

            if ! download_source "$archive" "$pending_dir"; then
                warn "Could not stage source for ${app_id}; leaving its generated files unchanged."
                skipped=$((skipped + 1))
                continue
            fi

            printf '%s\n' "$APP_SOURCE_REF" > "${runtime}/pending-ref"
            echo "Downloaded the configured source into source-pending."
        fi
    fi

    # Regenerate only template files. Keep app.conf and existing source
    # directories intact.
    write_install_script "$app_definition_dir"
    write_verify_script "$app_definition_dir"
    write_remove_script "$app_definition_dir"
    write_nginx_config "$app_definition_dir"

    echo "Generated custom-app files refreshed for ${app_id}."
    refreshed=$((refreshed + 1))

done < <(app_ids)

echo
echo "Refresh complete."
echo "Refreshed: ${refreshed}"
echo "Skipped  : ${skipped}"
echo
echo "No application deployment or service restart was performed."
echo "Run the normal setup installer when you are ready to apply changes."
