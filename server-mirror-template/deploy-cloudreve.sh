#!/usr/bin/env bash
set -euo pipefail

set -a
source ./.env
set +a

mkdir -p "$CLOUDREVE_INSTALL_DIR"
mkdir -p "$WEB_ROOT"

if ! id -u cloudreve >/dev/null 2>&1; then
  useradd --system --home "$CLOUDREVE_INSTALL_DIR" --shell /sbin/nologin cloudreve || true
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) PKG_ARCH="amd64" ;;
  aarch64|arm64) PKG_ARCH="arm64" ;;
  *) echo "[!] 不支持的架构: $ARCH"; exit 1 ;;
esac

TMP_ZIP="/tmp/cloudreve_${CLOUDREVE_VERSION}_${PKG_ARCH}.zip"
URL="https://github.com/cloudreve/Cloudreve/releases/download/${CLOUDREVE_VERSION}/cloudreve_${CLOUDREVE_VERSION}_linux_${PKG_ARCH}.zip"

curl -fL "$URL" -o "$TMP_ZIP"
unzip -o "$TMP_ZIP" -d "$CLOUDREVE_INSTALL_DIR"
chmod +x "$CLOUDREVE_INSTALL_DIR/cloudreve"

cat > "$CLOUDREVE_INSTALL_DIR/conf.ini" <<EOF
[System]
Mode = master
Listen = 127.0.0.1:${CLOUDREVE_PORT}

[Database]
Type = mysql
Port = 3306
User = ${CLOUDREVE_DB_USER}
Password = ${CLOUDREVE_DB_PASS}
Host = 127.0.0.1
Name = ${CLOUDREVE_DB_NAME}
TablePrefix = cd_
EOF

mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS \
  \
\\`${CLOUDREVE_DB_NAME}\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${CLOUDREVE_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${CLOUDREVE_DB_PASS}';
CREATE USER IF NOT EXISTS '${CLOUDREVE_DB_USER}'@'localhost' IDENTIFIED BY '${CLOUDREVE_DB_PASS}';
GRANT ALL PRIVILEGES ON \\`${CLOUDREVE_DB_NAME}\\`.* TO '${CLOUDREVE_DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \\`${CLOUDREVE_DB_NAME}\\`.* TO '${CLOUDREVE_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

chown -R cloudreve:cloudreve "$CLOUDREVE_INSTALL_DIR"

cat > /etc/systemd/system/cloudreve.service <<EOF
[Unit]
Description=Cloudreve
After=network.target mariadb.service mysql.service

[Service]
Type=simple
WorkingDirectory=${CLOUDREVE_INSTALL_DIR}
ExecStart=${CLOUDREVE_INSTALL_DIR}/cloudreve
Restart=on-failure
RestartSec=2s
User=cloudreve
Group=cloudreve

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudreve
systemctl status cloudreve --no-pager || true

echo "[+] Cloudreve 部署完成"
