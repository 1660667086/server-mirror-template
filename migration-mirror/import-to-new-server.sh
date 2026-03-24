#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_PATH="${1:-/root/server-mirror-export.tar.gz}"
RESTORE_DIR=/root/server-mirror-restore

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "[!] 找不到迁移包: $ARCHIVE_PATH"
  exit 1
fi

mkdir -p "$RESTORE_DIR"
rm -rf "$RESTORE_DIR"/*
tar -C "$RESTORE_DIR" -xzf "$ARCHIVE_PATH"

if command -v apt >/dev/null 2>&1; then
  apt update
  apt install -y nginx mariadb-server aria2 curl
  systemctl enable --now nginx mariadb
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y nginx mariadb-server aria2 curl
  systemctl enable --now nginx mariadb
elif command -v yum >/dev/null 2>&1; then
  yum install -y epel-release || true
  yum install -y nginx mariadb-server aria2 curl
  systemctl enable --now nginx mariadb
else
  echo "[!] 不支持的系统包管理器"
  exit 1
fi

echo "[+] 恢复 Cloudreve 目录"
mkdir -p /usr/local/lighthouse/softwares
if [[ -d "$RESTORE_DIR/cloudreve/cloudreve" ]]; then
  rm -rf /usr/local/lighthouse/softwares/cloudreve
  cp -a "$RESTORE_DIR/cloudreve/cloudreve" /usr/local/lighthouse/softwares/cloudreve
fi

echo "[+] 恢复 aria2 配置"
mkdir -p /usr/local/lighthouse/softwares/aria2
if [[ -d "$RESTORE_DIR/aria2/conf" ]]; then
  rm -rf /usr/local/lighthouse/softwares/aria2/conf
  cp -a "$RESTORE_DIR/aria2/conf" /usr/local/lighthouse/softwares/aria2/conf
fi

echo "[+] 恢复 Nginx 配置（按通用 Nginx 路径落地）"
mkdir -p /etc/nginx/conf.d
if [[ -f "$RESTORE_DIR/nginx/cloudreve.local.conf" ]]; then
  cat > /etc/nginx/conf.d/cloudreve-migrated.conf <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    root /usr/local/lighthouse/softwares/cloudreve;

    location / {
        proxy_pass http://127.0.0.1:5212;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header REMOTE-HOST $remote_addr;
        client_max_body_size 0;
    }

    location ~ \.well-known {
        allow all;
    }
}
EOF
fi

echo "[+] 恢复 Cloudreve systemd 服务"
if [[ -f "$RESTORE_DIR/systemd/cloudreve.service" ]]; then
  cp -f "$RESTORE_DIR/systemd/cloudreve.service" /etc/systemd/system/cloudreve.service
else
  cat > /etc/systemd/system/cloudreve.service <<'EOF'
[Unit]
Description=Cloudreve
After=network.target mariadb.service aria2.service

[Service]
Type=simple
WorkingDirectory=/usr/local/lighthouse/softwares/cloudreve
ExecStart=/usr/local/lighthouse/softwares/cloudreve/cloudreve
Restart=on-failure
RestartSec=2s
KillMode=mixed
StandardOutput=null
StandardError=syslog

[Install]
WantedBy=multi-user.target
EOF
fi

if [[ -f "$RESTORE_DIR/db/cloudreve.sql" ]]; then
  echo "[+] 导入 cloudreve 数据库"
  mysql -uroot -e "CREATE DATABASE IF NOT EXISTS cloudreve CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -uroot cloudreve < "$RESTORE_DIR/db/cloudreve.sql"
else
  echo "[!] 未发现 SQL 备份，跳过数据库导入"
fi

systemctl daemon-reload
systemctl enable --now aria2 || true
systemctl enable --now cloudreve || true
nginx -t && systemctl reload nginx || true

echo "[+] 迁移恢复完成"
echo "[!] 你还需要手动确认：域名、证书、数据库账号密码、外部访问路径。"
