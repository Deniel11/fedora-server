#!/usr/bin/env bash
set -Eeuo pipefail

runtime="/opt/fedora-server-apps/goaccess"
source "${runtime}/.env"

while [[ ! -r /var/log/nginx/access.log ]]; do
    sleep 2
done

exec tail -n +1 -F /var/log/nginx/*access*.log |
    docker exec -i goaccess-processor goaccess - \
        --log-format=COMBINED \
        --real-time-html \
        --ws-url="wss://${APP_DOMAIN}/ws" \
        --addr=0.0.0.0 \
        --port=7890 \
        -o /report/index.html
