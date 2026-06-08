#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_PATH="${1:-/root/server-mirror-export.tar.gz}"
RESTORE_DIR=/root/server-mirror-restore

ensure_low_memory_swap() {
  local mem_total_kb=""
  local swap_total_kb=""
  local swap_mb=""

  if [[ ! -r /proc/meminfo ]]; then
    return 0
  fi

  mem_total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  swap_total_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"

  if [[ -z "$mem_total_kb" || -z "$swap_total_kb" ]]; then
    return 0
  fi

  if (( swap_total_kb > 0 )); then
    return 0
  fi

  if (( mem_total_kb <= 1200000 )); then
    swap_mb=2048
  elif (( mem_total_kb <= 2000000 )); then
    swap_mb=1024
  else
    return 0
  fi

  echo "[+] 检测到小内存机器，自动创建 ${swap_mb}MB swap"

  if [[ ! -f /swapfile ]]; then
    if command -v fallocate >/dev/null 2>&1; then
      fallocate -l "${swap_mb}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=progress
    else
      dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=progress
    fi
  fi

  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile

  if ! grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
}

install_runtime_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    dpkg --configure -a || true
    apt-get -f install -y || true
    dpkg --configure -a
    apt-get update
    apt-get install -y nginx mariadb-server aria2 curl
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
}

ensure_aria2_service() {
  local unit_path=""

  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'aria2.service'; then
    return 0
  fi

  if [[ -f /etc/systemd/system/aria2.service ]]; then
    unit_path=/etc/systemd/system/aria2.service
  elif [[ -f /usr/lib/systemd/system/aria2.service ]]; then
    unit_path=/usr/lib/systemd/system/aria2.service
  elif [[ -f /lib/systemd/system/aria2.service ]]; then
    unit_path=/lib/systemd/system/aria2.service
  else
    unit_path=/etc/systemd/system/aria2.service
    mkdir -p /usr/local/lighthouse/softwares/aria2/conf
    mkdir -p /usr/local/lighthouse/softwares/aria2/downloads
    cat > "$unit_path" <<'EOF'
[Unit]
Description=Aria2c Download Manager
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/aria2c --conf-path=/usr/local/lighthouse/softwares/aria2/conf/aria2.conf
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
}

ensure_trojan_services() {
  local trojan_bin=""
  local trojan_ctl=""

  if [[ -x /usr/bin/trojan/trojan ]]; then
    trojan_bin=/usr/bin/trojan/trojan
  elif [[ -x /usr/local/bin/trojan ]]; then
    trojan_bin=/usr/local/bin/trojan
  fi

  if [[ -x /usr/local/bin/trojan ]]; then
    trojan_ctl=/usr/local/bin/trojan
  elif [[ -n "$trojan_bin" ]]; then
    trojan_ctl="$trojan_bin"
  fi

  if [[ -n "$trojan_bin" && -f /usr/local/etc/trojan/config.json && ! -f /etc/systemd/system/trojan.service ]]; then
    cat > /etc/systemd/system/trojan.service <<EOF
[Unit]
Description=trojan
After=network.target network-online.target nss-lookup.target mysql.service mariadb.service mysqld.service

[Service]
Type=simple
StandardError=journal
ExecStart=${trojan_bin} -config /usr/local/etc/trojan/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  fi

  if [[ -n "$trojan_ctl" && ! -f /etc/systemd/system/trojan-web.service ]]; then
    cat > /etc/systemd/system/trojan-web.service <<EOF
[Unit]
Description=trojan-web
After=network.target network-online.target nss-lookup.target mysql.service mariadb.service mysqld.service docker.service

[Service]
Type=simple
StandardError=journal
ExecStart=${trojan_ctl} web
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
}

parse_ini_value() {
  local file="$1"
  local section="$2"
  local key="$3"

  awk -F= -v target_section="$section" -v target_key="$key" '
    $0 ~ "^\\[" target_section "\\]$" {
      in_section=1
      next
    }
    /^\[/ {
      in_section=0
    }
    in_section {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ "^" target_key "[[:space:]]*=") {
        sub("^[^=]*=[[:space:]]*", "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  ' "$file"
}

sql_escape_string() {
  printf '%s' "$1" | sed "s/'/''/g"
}

ensure_cloudreve_db_user() {
  local conf_file=/usr/local/lighthouse/softwares/cloudreve/conf.ini
  local db_type=""
  local db_host=""
  local db_name=""
  local db_user=""
  local db_password=""
  local escaped_db_name=""
  local escaped_db_user=""
  local escaped_db_password=""

  if [[ ! -f "$conf_file" ]]; then
    return 0
  fi

  db_type="$(parse_ini_value "$conf_file" Database Type)"
  db_host="$(parse_ini_value "$conf_file" Database Host)"
  db_name="$(parse_ini_value "$conf_file" Database Name)"
  db_user="$(parse_ini_value "$conf_file" Database User)"
  db_password="$(parse_ini_value "$conf_file" Database Password)"

  if [[ "$db_type" != "mysql" || -z "$db_name" || -z "$db_user" ]]; then
    return 0
  fi

  case "$db_host" in
    ""|"127.0.0.1"|"localhost")
      ;;
    *)
      echo "[!] Cloudreve 使用远程数据库 $db_host，跳过本地数据库用户创建"
      return 0
      ;;
  esac

  escaped_db_name="$(sql_escape_string "$db_name")"
  escaped_db_user="$(sql_escape_string "$db_user")"
  escaped_db_password="$(sql_escape_string "$db_password")"

  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${escaped_db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`${escaped_db_name}\`.* TO '${escaped_db_user}'@'localhost' IDENTIFIED BY '${escaped_db_password}';
GRANT ALL PRIVILEGES ON \`${escaped_db_name}\`.* TO '${escaped_db_user}'@'127.0.0.1' IDENTIFIED BY '${escaped_db_password}';
FLUSH PRIVILEGES;
SQL
}

write_cloudreve_nginx_conf() {
  local target="$1"

  cat > "$target" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:5212;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header REMOTE-HOST $remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ~ /\.well-known {
        allow all;
    }
}
EOF
}

disable_default_nginx_site() {
  if [[ -L /etc/nginx/sites-enabled/default || -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  if [[ -f /etc/nginx/conf.d/default.conf ]]; then
    mv -f /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled-by-server-mirror
  fi
}

normalize_directory_permissions() {
  local target="$1"
  if [[ -d "$target" ]]; then
    find "$target" -type d -exec chmod 755 {} +
  fi
}

enable_if_unit_exists() {
  local unit="$1"
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "$unit"; then
    systemctl enable --now "${unit%.service}" || true
  fi
}

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "[!] 找不到迁移包: $ARCHIVE_PATH"
  exit 1
fi

mkdir -p "$RESTORE_DIR"
rm -rf "$RESTORE_DIR"/*
tar -C "$RESTORE_DIR" -xzf "$ARCHIVE_PATH"

ensure_low_memory_swap
install_runtime_packages

echo "[+] 恢复 Cloudreve 目录"
mkdir -p /usr/local/lighthouse/softwares
if [[ -d "$RESTORE_DIR/cloudreve/cloudreve" ]]; then
  rm -rf /usr/local/lighthouse/softwares/cloudreve
  cp -a "$RESTORE_DIR/cloudreve/cloudreve" /usr/local/lighthouse/softwares/cloudreve
fi
normalize_directory_permissions /usr/local/lighthouse/softwares/cloudreve
chmod +x /usr/local/lighthouse/softwares/cloudreve/cloudreve 2>/dev/null || true

echo "[+] 恢复 aria2 配置"
mkdir -p /usr/local/lighthouse/softwares/aria2
if [[ -d "$RESTORE_DIR/aria2/conf" ]]; then
  rm -rf /usr/local/lighthouse/softwares/aria2/conf
  cp -a "$RESTORE_DIR/aria2/conf" /usr/local/lighthouse/softwares/aria2/conf
fi
normalize_directory_permissions /usr/local/lighthouse/softwares/aria2
mkdir -p /usr/local/lighthouse/softwares/aria2/downloads

echo "[+] 恢复 Nginx 配置（生成通用 Cloudreve 反代站点）"
mkdir -p /etc/nginx/conf.d
if [[ -f "$RESTORE_DIR/nginx/cloudreve.local.conf" ]]; then
  cp -f "$RESTORE_DIR/nginx/cloudreve.local.conf" /root/server-mirror-restored-cloudreve.local.conf
fi
write_cloudreve_nginx_conf /etc/nginx/conf.d/cloudreve-migrated.conf
disable_default_nginx_site

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

echo "[+] 恢复 trojan 文件"
if [[ -d "$RESTORE_DIR/trojan/fs" ]]; then
  (cd "$RESTORE_DIR/trojan/fs" && tar -cf - .) | tar -xf - -C /
fi
chmod +x /usr/local/bin/trojan /usr/bin/trojan/trojan 2>/dev/null || true

if [[ -f "$RESTORE_DIR/db/cloudreve.sql" ]]; then
  echo "[+] 导入 cloudreve 数据库"
  mysql -uroot -e "CREATE DATABASE IF NOT EXISTS cloudreve CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -uroot cloudreve < "$RESTORE_DIR/db/cloudreve.sql"
else
  echo "[!] 未发现 SQL 备份，跳过数据库导入"
fi

ensure_cloudreve_db_user
ensure_aria2_service
ensure_trojan_services
systemctl daemon-reload
enable_if_unit_exists aria2.service
enable_if_unit_exists trojan.service
enable_if_unit_exists trojan-web.service
enable_if_unit_exists cloudreve.service
systemctl restart cloudreve || true
nginx -t && systemctl reload nginx || true

echo "[+] 迁移恢复完成"
echo "[!] 你还需要手动确认：域名、证书、数据库账号密码、外部访问路径。"
