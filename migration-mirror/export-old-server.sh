#!/usr/bin/env bash
set -euo pipefail

EXPORT_DIR=/root/server-mirror-export
STAGE_DIR="$EXPORT_DIR/stage"
ARCHIVE_PATH="$EXPORT_DIR/server-mirror-export.tar.gz"

mkdir -p "$STAGE_DIR"
rm -rf "$STAGE_DIR"/*
mkdir -p "$STAGE_DIR/cloudreve" "$STAGE_DIR/aria2" "$STAGE_DIR/nginx" "$STAGE_DIR/systemd" "$STAGE_DIR/db"

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

echo "[+] 导出 Cloudreve 目录"
copy_if_exists /usr/local/lighthouse/softwares/cloudreve "$STAGE_DIR/cloudreve/cloudreve"

echo "[+] 导出 aria2 配置"
copy_if_exists /usr/local/lighthouse/softwares/aria2/conf "$STAGE_DIR/aria2/conf"

echo "[+] 导出 nginx 配置"
copy_if_exists /www/server/panel/vhost/nginx/cloudreve.local.conf "$STAGE_DIR/nginx/cloudreve.local.conf"
copy_if_exists /www/server/panel/vhost/nginx/proxy/cloudreve.local "$STAGE_DIR/nginx/proxy/cloudreve.local"

echo "[+] 导出 systemd 服务"
copy_if_exists /usr/lib/systemd/system/cloudreve.service "$STAGE_DIR/systemd/cloudreve.service"

if mysql -Nse "SHOW DATABASES LIKE 'cloudreve';" 2>/dev/null | grep -q cloudreve; then
  echo "[+] 导出 cloudreve 数据库"
  mysqldump --single-transaction --quick cloudreve > "$STAGE_DIR/db/cloudreve.sql"
else
  echo "[!] 未发现 cloudreve 数据库，跳过 SQL 导出"
fi

cat > "$STAGE_DIR/MANIFEST.txt" <<EOF
exported_at=$(date -Is)
hostname=$(hostname)
cloudreve_dir=/usr/local/lighthouse/softwares/cloudreve
aria2_conf=/usr/local/lighthouse/softwares/aria2/conf
nginx_vhost=/www/server/panel/vhost/nginx/cloudreve.local.conf
EOF

mkdir -p "$EXPORT_DIR"
tar -C "$STAGE_DIR" -czf "$ARCHIVE_PATH" .

echo "[+] 导出完成: $ARCHIVE_PATH"
ls -lh "$ARCHIVE_PATH"
