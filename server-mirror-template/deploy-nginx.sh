#!/usr/bin/env bash
set -euo pipefail

set -a
source ./.env
set +a

mkdir -p "$WEB_ROOT"

cat > "/etc/nginx/conf.d/cloudreve.conf" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:${CLOUDREVE_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
    }
}
EOF

nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "[+] Nginx 反向代理部署完成"
