#!/usr/bin/env bash
set -Eeuo pipefail

runtime="/opt/fedora-server-apps/goaccess"
source "${runtime}/.env"

collect_log_files() {
    local marker app_dir app_id path
    local -a files=()
    shopt -s nullglob

    for path in /var/log/nginx/access.log*; do
        [[ -f "$path" ]] && files+=("$path")
    done

    for marker in /opt/fedora-server-apps/*/.installed; do
        [[ -f "$marker" ]] || continue
        app_dir="${marker%/.installed}"
        app_id="${app_dir##*/}"
        [[ -f "/etc/nginx/conf.d/${app_id}.conf" ]] || continue
        files+=("/var/log/nginx/${app_id}-access.log")
    done

    printf '%s\n' "${files[@]}"
}

while :; do
    mapfile -t log_files < <(collect_log_files)
    ready=false
    for log_file in "${log_files[@]}"; do
        if [[ -r "$log_file" ]]; then
            ready=true
            break
        fi
    done
    [[ "$ready" == true ]] && break
    sleep 2
done

exec tail -q -n +1 -F "${log_files[@]}" |
    docker exec -i goaccess-processor goaccess - \
        --log-format=COMBINED \
        --real-time-html \
        --ws-url="wss://${APP_DOMAIN}/ws" \
        --addr=0.0.0.0 \
        --port=443 \
        -o /report/index.html
