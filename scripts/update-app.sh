#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
ensure_dirs

custom_apps=()

while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue
    load_app_config "$app_id" || continue
    [[ "${APP_TYPE:-}" == "custom" ]] || continue
    app_is_installed "$app_id" && custom_apps+=("$app_id")
done < <(app_ids)

if ((${#custom_apps[@]} == 0)); then
    echo "No installed custom applications were found."
    exit 0
fi

echo
echo "========================================"
echo " Update application source"
echo "========================================"
echo
echo "This operation downloads source only."
echo "It does not deploy, rebuild, restart, or reload applications."
echo

for index in "${!custom_apps[@]}"; do
    app_id="${custom_apps[$index]}"
    load_app_config "$app_id"
    printf '  %d) %s (%s)\n' \
        "$((index + 1))" \
        "$APP_NAME" \
        "$APP_ID"
done

echo
echo "Enter one or more application numbers separated by spaces."
echo "Enter all to select every custom application."
echo

read -r -p "Applications to update: " selection

[[ -n "$selection" ]] ||
    exit 0

selected=()

if [[ "$selection" == "all" || "$selection" == "ALL" ]]; then
    selected=("${custom_apps[@]}")
else
    for item in $selection; do
        [[ "$item" =~ ^[0-9]+$ ]] ||
            die "Invalid application selection: $item"

        ((item >= 1 && item <= ${#custom_apps[@]})) ||
            die "Application selection is outside the available range: $item"

        app_id="${custom_apps[$((item - 1))]}"

        if [[ ! " ${selected[*]} " == *" ${app_id} "* ]]; then
            selected+=("$app_id")
        fi
    done
fi

echo
echo "Selected applications:"

for app_id in "${selected[@]}"; do
    load_app_config "$app_id"
    printf '  - %s (%s -> %s)\n' \
        "$APP_NAME" \
        "$APP_ID" \
        "$APP_SOURCE_REF"
done

echo
echo "Final action:"
echo "  1) All"
echo "  2) Cancel"
echo

read -r -p "Choose [1-2]: " action

case "$action" in
    1)
        ;;
    2)
        echo "Source update cancelled."
        exit 0
        ;;
    *)
        die "Invalid selection."
        ;;
esac

for app_id in "${selected[@]}"; do
    load_app_config "$app_id"

    runtime="$(app_runtime_dir "$app_id")"
    pending="${runtime}/source-pending"
    archive="$(printf '%s/archive/%s.tar.gz' "${APP_SOURCE_URL%/}" "$APP_SOURCE_REF")"

    echo
    echo "Updating source: ${APP_NAME}"
    echo "Archive: ${archive}"

    rm -rf "$pending"

    mkdir -p "$pending"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 2 \
        --connect-timeout 15 \
        --max-time 300 \
        "$archive" \
        -o "${runtime}/source-update.tar.gz" ||
        die "Source download failed for ${APP_ID}."

    tar -xzf "${runtime}/source-update.tar.gz" -C "$pending" ||
        die "Source archive extraction failed for ${APP_ID}."

    rm -f "${runtime}/source-update.tar.gz"

    entries=()

    while IFS= read -r entry; do
        entries+=("$entry")
    done < <(find "$pending" -mindepth 1 -maxdepth 1 -type d -print)

    if ((${#entries[@]} == 1)); then
        root="${entries[0]}"
        tmp="${runtime}/source-update-flat"
        rm -rf "$tmp"
        mkdir -p "$tmp"
        cp -a "${root}/." "$tmp/"
        rm -rf "$pending"
        mv "$tmp" "$pending"
    fi

    printf '%s\n' "$APP_SOURCE_REF" > "${runtime}/pending-ref"

    echo "Source update staged for ${APP_ID}."
done

echo
echo "Source update completed."
echo "No application deployment was performed."
echo "Run the normal application installation/deployment action when you want to activate the staged source."