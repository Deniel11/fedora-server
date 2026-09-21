#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

require_root
require_fedora
load_config
ensure_dirs

install -d -m 0755 /etc/nginx/conf.d

TLS_DIR="/etc/fedora-server-setup/tls"

cat > /etc/nginx/conf.d/portainer.conf <<EOF
server {
    listen 80;
    server_name ${PORTAINER_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${PORTAINER_DOMAIN};

    ssl_certificate ${TLS_DIR}/portainer.crt;
    ssl_certificate_key ${TLS_DIR}/portainer.key;

    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 128m;

    location / {
        proxy_pass https://127.0.0.1:9443;
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
    listen 443 ssl http2;
    server_name ${VAULTWARDEN_DOMAIN};

    ssl_certificate ${TLS_DIR}/vaultwarden.crt;
    ssl_certificate_key ${TLS_DIR}/vaultwarden.key;

    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 128m;

    location / {
        proxy_pass http://127.0.0.1:8080;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /notifications/hub {
        proxy_pass http://127.0.0.1:3012;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 86400;
    }
}
EOF

nginx -t
systemctl enable --now nginx
systemctl reload nginx

log "Nginx reverse proxy is ready."
