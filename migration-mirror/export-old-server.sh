#!/usr/bin/env bash
set -euo pipefail

EXPORT_DIR=/root/server-mirror-export
STAGE_DIR="$EXPORT_DIR/stage"
ARCHIVE_PATH="$EXPORT_DIR/server-mirror-export.tar.gz"

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

copy_abs_if_exists() {
  local src="$1"
  local root="$2"
  if [[ -e "$src" ]]; then
    local rel="${src#/}"
    mkdir -p "$root/$(dirname "$rel")"
    cp -a "$src" "$root/$rel"
  fi
}

trojan_service_path() {
  local name="$1"
  local candidate
  for candidate in \
    "/etc/systemd/system/$name" \
    "/usr/lib/systemd/system/$name" \
    "/lib/systemd/system/$name"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

extract_execstart_binary() {
  local service_path="$1"
  awk -F= '/^ExecStart=/{print $2; exit}' "$service_path" | awk '{print $1}'
}

extract_config_path() {
  local service_path="$1"
  awk -F= '/^ExecStart=/{print $2; exit}' "$service_path" | sed -nE 's/.*-config[[:space:]]+([^[:space:]]+).*/\1/p'
}

trojan_json_value() {
  local json_file="$1"
  local key="$2"
  grep -E "\"$key\"[[:space:]]*:" "$json_file" | head -n1 | sed -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

mkdir -p "$STAGE_DIR"
rm -rf "$STAGE_DIR"/*
mkdir -p \
  "$STAGE_DIR/cloudreve" \
  "$STAGE_DIR/aria2" \
  "$STAGE_DIR/nginx" \
  "$STAGE_DIR/systemd" \
  "$STAGE_DIR/db" \
  "$STAGE_DIR/trojan"

echo "[+] 导出 Cloudreve 目录"
copy_if_exists /usr/local/lighthouse/softwares/cloudreve "$STAGE_DIR/cloudreve/cloudreve"

echo "[+] 导出 aria2 配置"
copy_if_exists /usr/local/lighthouse/softwares/aria2/conf "$STAGE_DIR/aria2/conf"

echo "[+] 导出 nginx 配置"
copy_if_exists /www/server/panel/vhost/nginx/cloudreve.local.conf "$STAGE_DIR/nginx/cloudreve.local.conf"
copy_if_exists /www/server/panel/vhost/nginx/proxy/cloudreve.local "$STAGE_DIR/nginx/proxy/cloudreve.local"

echo "[+] 导出 systemd 服务"
copy_if_exists /usr/lib/systemd/system/cloudreve.service "$STAGE_DIR/systemd/cloudreve.service"
copy_if_exists /etc/systemd/system/cloudreve.service "$STAGE_DIR/systemd/cloudreve.service"

echo "[+] 导出 trojan 相关文件"
TROJAN_SERVICE_PATH="$(trojan_service_path trojan.service || true)"
TROJAN_WEB_SERVICE_PATH="$(trojan_service_path trojan-web.service || true)"
TROJAN_CONFIG_PATH=""

if [[ -n "$TROJAN_SERVICE_PATH" ]]; then
  copy_abs_if_exists "$TROJAN_SERVICE_PATH" "$STAGE_DIR/trojan/fs"
  TROJAN_BIN_PATH="$(extract_execstart_binary "$TROJAN_SERVICE_PATH")"
  TROJAN_CONFIG_PATH="$(extract_config_path "$TROJAN_SERVICE_PATH")"
  if [[ -n "$TROJAN_BIN_PATH" ]]; then
    copy_abs_if_exists "$TROJAN_BIN_PATH" "$STAGE_DIR/trojan/fs"
  fi
fi

if [[ -n "$TROJAN_WEB_SERVICE_PATH" ]]; then
  copy_abs_if_exists "$TROJAN_WEB_SERVICE_PATH" "$STAGE_DIR/trojan/fs"
  TROJAN_WEB_BIN_PATH="$(extract_execstart_binary "$TROJAN_WEB_SERVICE_PATH")"
  if [[ -n "$TROJAN_WEB_BIN_PATH" ]]; then
    copy_abs_if_exists "$TROJAN_WEB_BIN_PATH" "$STAGE_DIR/trojan/fs"
  fi
fi

if [[ -z "$TROJAN_CONFIG_PATH" && -f /usr/local/etc/trojan/config.json ]]; then
  TROJAN_CONFIG_PATH=/usr/local/etc/trojan/config.json
fi

if [[ -n "$TROJAN_CONFIG_PATH" && -f "$TROJAN_CONFIG_PATH" ]]; then
  copy_abs_if_exists "$(dirname "$TROJAN_CONFIG_PATH")" "$STAGE_DIR/trojan/fs"

  TROJAN_CERT_PATH="$(trojan_json_value "$TROJAN_CONFIG_PATH" cert)"
  TROJAN_KEY_PATH="$(trojan_json_value "$TROJAN_CONFIG_PATH" key)"
  TROJAN_CAFILE_PATH="$(trojan_json_value "$TROJAN_CONFIG_PATH" cafile)"

  if [[ -n "$TROJAN_CERT_PATH" ]]; then
    copy_abs_if_exists "$TROJAN_CERT_PATH" "$STAGE_DIR/trojan/fs"
  fi
  if [[ -n "$TROJAN_KEY_PATH" ]]; then
    copy_abs_if_exists "$TROJAN_KEY_PATH" "$STAGE_DIR/trojan/fs"
  fi
  if [[ -n "$TROJAN_CAFILE_PATH" ]]; then
    copy_abs_if_exists "$TROJAN_CAFILE_PATH" "$STAGE_DIR/trojan/fs"
  fi
fi

copy_abs_if_exists /usr/local/bin/trojan "$STAGE_DIR/trojan/fs"
copy_abs_if_exists /usr/bin/trojan "$STAGE_DIR/trojan/fs"

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
trojan_service=${TROJAN_SERVICE_PATH:-}
trojan_web_service=${TROJAN_WEB_SERVICE_PATH:-}
trojan_config=${TROJAN_CONFIG_PATH:-}
EOF

mkdir -p "$EXPORT_DIR"
tar -C "$STAGE_DIR" -czf "$ARCHIVE_PATH" .

echo "[+] 导出完成: $ARCHIVE_PATH"
ls -lh "$ARCHIVE_PATH"
