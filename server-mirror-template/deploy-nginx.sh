#!/usr/bin/env bash
set -euo pipefail

set -a
source ./.env
set +a

mkdir -p "$NGINX_CONF_DIR"
mkdir -p "$WEB_ROOT"

cat > "${NGINX_CONF_DIR}/cloudreve.conf" <<EOF
server {
    listen 80 default_server;
    server_name ${DOMAIN};
    index index.php index.html index.htm default.php default.htm default.html;
    root ${WEB_ROOT};

    location / {
        proxy_pass http://127.0.0.1:${CLOUDREVE_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header REMOTE-HOST \$remote_addr;
        add_header X-Cache \$upstream_cache_status;
        add_header Cache-Control no-cache;
        expires 12h;
        client_max_body_size 0;
    }

    location ~ ^/(\.user.ini|\.htaccess|\.git|\.svn|\.project|LICENSE|README.md) {
        return 404;
    }

    location ~ \.well-known {
        allow all;
    }
}
EOF

nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "[+] Nginx（现网复刻版）配置完成"
