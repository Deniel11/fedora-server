#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
ensure_dirs

install -d -m 0755 /etc/nginx/conf.d
TLS_DIR="/etc/fedora-server-setup/tls"

# Nginx needs permission to connect to the local Docker-published
# application ports when SELinux is enforcing.
if command -v getsebool >/dev/null 2>&1 && command -v setsebool >/dev/null 2>&1; then
    if getsebool httpd_can_network_connect 2>/dev/null | grep -q -- ' --> off$'; then
        log "Enabling SELinux httpd_can_network_connect for Nginx reverse proxy."
        setsebool -P httpd_can_network_connect 1
    fi
fi

cat > /etc/nginx/conf.d/portainer.conf <<EOF
server {
    listen 80;
    server_name ${PORTAINER_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    http2 on;
    server_name ${PORTAINER_DOMAIN};
    ssl_certificate ${TLS_DIR}/portainer.crt;
    ssl_certificate_key ${TLS_DIR}/portainer.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 128m;
    location / {
        proxy_pass https://127.0.0.1:${PORTAINER_PORT};
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

cat > /etc/nginx/conf.d/vaultwarden.conf <<EOF
server {
    listen 80;
    server_name ${VAULTWARDEN_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    http2 on;
    server_name ${VAULTWARDEN_DOMAIN};
    ssl_certificate ${TLS_DIR}/vaultwarden.crt;
    ssl_certificate_key ${TLS_DIR}/vaultwarden.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 128m;
    location / {
        proxy_pass http://127.0.0.1:${VAULTWARDEN_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location /notifications/hub {
        proxy_pass http://127.0.0.1:${VAULTWARDEN_NOTIFICATIONS_HUB_PORT};
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 86400;
    }
}
EOF

cat > /etc/nginx/conf.d/joplin.conf <<EOF
server {
    listen 80;
    server_name ${JOPLIN_DOMAIN};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;

    server_name ${JOPLIN_DOMAIN};

    ssl_certificate ${TLS_DIR}/joplin.crt;
    ssl_certificate_key ${TLS_DIR}/joplin.key;

    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 128m;

    location / {
        proxy_pass http://127.0.0.1:${JOPLIN_PORT};

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;
    }
}
EOF

nginx -t

if systemctl is-active --quiet nginx; then
    log "Nginx is already running; reloading configuration."
    systemctl reload nginx
else
    systemctl enable --now nginx
fi

log "Nginx reverse proxy is ready."