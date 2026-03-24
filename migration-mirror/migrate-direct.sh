#!/usr/bin/env bash
set -euo pipefail

OLD_HOST="${1:-}"
OLD_USER="${2:-root}"
OLD_PASSWORD="${3:-}"

if [[ -z "$OLD_HOST" || -z "$OLD_PASSWORD" ]]; then
  echo "用法: bash migrate-direct.sh <OLD_HOST> [OLD_USER] <OLD_PASSWORD>"
  echo "示例: bash migrate-direct.sh 43.133.45.158 root 'your-password'"
  exit 1
fi

if [[ "$#" -eq 2 ]]; then
  OLD_PASSWORD="$2"
  OLD_USER="root"
fi

WORKDIR=/root/server-direct-mirror
EXPORT_TGZ="$WORKDIR/server-mirror-export.tar.gz"
STAGE_DIR="$WORKDIR/stage"
mkdir -p "$WORKDIR" "$STAGE_DIR"

install_pkg() {
  if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y curl git nano nginx mariadb-server aria2 python3 python3-pip
    systemctl enable --now nginx mariadb
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl git nano nginx mariadb-server aria2 python3 python3-pip
    systemctl enable --now nginx mariadb
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y curl git nano nginx mariadb-server aria2 python3 python3-pip
    systemctl enable --now nginx mariadb
  else
    echo "[!] 不支持的系统包管理器"
    exit 1
  fi
}

install_pkg
python3 -m pip install --break-system-packages --quiet paramiko || python3 -m pip install --quiet paramiko

PYTHON_SCRIPT="$WORKDIR/direct_fetch.py"
cat > "$PYTHON_SCRIPT" <<'PY'
import io, os, tarfile, posixpath, paramiko, sys

old_host = sys.argv[1]
old_user = sys.argv[2]
old_password = sys.argv[3]
out_path = sys.argv[4]

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(old_host, username=old_user, password=old_password, timeout=20, banner_timeout=20, auth_timeout=20)
sftp = client.open_sftp()

def exists(path):
    try:
        sftp.stat(path)
        return True
    except IOError:
        return False

def add_file(tf, remote_path, arcname):
    with sftp.open(remote_path, 'rb') as f:
        data = f.read()
    ti = tarfile.TarInfo(name=arcname)
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))

def add_tree(tf, remote_path, arcroot):
    if not exists(remote_path):
        return
    stack = [(remote_path, arcroot)]
    while stack:
        rp, ap = stack.pop()
        st = sftp.stat(rp)
        if str(st).startswith(''):  # no-op; keep pyflakes quiet
            pass
        try:
            entries = sftp.listdir_attr(rp)
            ti = tarfile.TarInfo(name=ap)
            ti.type = tarfile.DIRTYPE
            tf.addfile(ti)
            for ent in entries:
                child_rp = posixpath.join(rp, ent.filename)
                child_ap = posixpath.join(ap, ent.filename)
                # if directory bit set
                if ent.st_mode & 0o40000:
                    stack.append((child_rp, child_ap))
                else:
                    with sftp.open(child_rp, 'rb') as f:
                        data = f.read()
                    ti = tarfile.TarInfo(name=child_ap)
                    ti.size = len(data)
                    tf.addfile(ti, io.BytesIO(data))
        except IOError:
            with sftp.open(rp, 'rb') as f:
                data = f.read()
            ti = tarfile.TarInfo(name=ap)
            ti.size = len(data)
            tf.addfile(ti, io.BytesIO(data))

with tarfile.open(out_path, 'w:gz') as tf:
    add_tree(tf, '/usr/local/lighthouse/softwares/cloudreve', 'cloudreve/cloudreve')
    add_tree(tf, '/usr/local/lighthouse/softwares/aria2/conf', 'aria2/conf')
    if exists('/www/server/panel/vhost/nginx/cloudreve.local.conf'):
        add_file(tf, '/www/server/panel/vhost/nginx/cloudreve.local.conf', 'nginx/cloudreve.local.conf')
    if exists('/usr/lib/systemd/system/cloudreve.service'):
        add_file(tf, '/usr/lib/systemd/system/cloudreve.service', 'systemd/cloudreve.service')
    # db dump
    stdin, stdout, stderr = client.exec_command("if mysql -Nse \"SHOW DATABASES LIKE 'cloudreve';\" 2>/dev/null | grep -q cloudreve; then mysqldump --single-transaction --quick cloudreve; fi", timeout=120)
    sql = stdout.read()
    if sql:
        ti = tarfile.TarInfo(name='db/cloudreve.sql')
        ti.size = len(sql)
        tf.addfile(ti, io.BytesIO(sql))

client.close()
PY

python3 "$PYTHON_SCRIPT" "$OLD_HOST" "$OLD_USER" "$OLD_PASSWORD" "$EXPORT_TGZ"

echo "[+] 已从旧服务器抓取迁移包: $EXPORT_TGZ"

mkdir -p "$STAGE_DIR"
rm -rf "$STAGE_DIR"/*
tar -C "$STAGE_DIR" -xzf "$EXPORT_TGZ"

mkdir -p /usr/local/lighthouse/softwares
if [[ -d "$STAGE_DIR/cloudreve/cloudreve" ]]; then
  rm -rf /usr/local/lighthouse/softwares/cloudreve
  cp -a "$STAGE_DIR/cloudreve/cloudreve" /usr/local/lighthouse/softwares/cloudreve
fi
if [[ -d "$STAGE_DIR/aria2/conf" ]]; then
  mkdir -p /usr/local/lighthouse/softwares/aria2
  rm -rf /usr/local/lighthouse/softwares/aria2/conf
  cp -a "$STAGE_DIR/aria2/conf" /usr/local/lighthouse/softwares/aria2/conf
fi

mkdir -p /etc/nginx/conf.d
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

if [[ -f "$STAGE_DIR/systemd/cloudreve.service" ]]; then
  cp -f "$STAGE_DIR/systemd/cloudreve.service" /etc/systemd/system/cloudreve.service
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

if [[ -f "$STAGE_DIR/db/cloudreve.sql" ]]; then
  mysql -uroot -e "CREATE DATABASE IF NOT EXISTS cloudreve CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -uroot cloudreve < "$STAGE_DIR/db/cloudreve.sql" || true
fi

systemctl daemon-reload
systemctl enable --now aria2 || true
systemctl enable --now cloudreve || true
nginx -t && systemctl reload nginx || true

echo "[+] 新服务器直连旧服务器恢复完成"
echo "[!] 后续仍需确认：域名、证书、数据库登录方式、Cloudreve外链设置。"
