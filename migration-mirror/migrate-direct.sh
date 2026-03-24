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
    apt install -y curl git nano nginx mariadb-server aria2 python3 python3-pip python3-paramiko
    systemctl enable --now nginx mariadb
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl git nano nginx mariadb-server aria2 python3 python3-pip python3-paramiko || dnf install -y curl git nano nginx mariadb-server aria2 python3 python3-pip
    systemctl enable --now nginx mariadb
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y curl git nano nginx mariadb-server aria2 python3 python3-pip python3-paramiko || yum install -y curl git nano nginx mariadb-server aria2 python3 python3-pip
    systemctl enable --now nginx mariadb
  else
    echo "[!] 不支持的系统包管理器"
    exit 1
  fi
}

install_pkg
python3 -c "import paramiko" 2>/dev/null || python3 -m pip install --break-system-packages -q paramiko || true

PYTHON_SCRIPT="$WORKDIR/direct_fetch.py"
cat > "$PYTHON_SCRIPT" <<'PY'
import io, tarfile, posixpath, paramiko, sys, stat

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
    st = sftp.stat(remote_path)
    with sftp.open(remote_path, 'rb') as f:
        data = f.read()
    ti = tarfile.TarInfo(name=arcname)
    ti.size = len(data)
    ti.mode = st.st_mode & 0o777
    tf.addfile(ti, io.BytesIO(data))

def add_tree(tf, remote_path, arcroot):
    if not exists(remote_path):
        return
    stack = [(remote_path, arcroot)]
    while stack:
        rp, ap = stack.pop()
        st = sftp.stat(rp)
        if stat.S_ISDIR(st.st_mode):
            ti = tarfile.TarInfo(name=ap)
            ti.type = tarfile.DIRTYPE
            ti.mode = st.st_mode & 0o777
            tf.addfile(ti)
            for ent in sftp.listdir_attr(rp):
                child_rp = posixpath.join(rp, ent.filename)
                child_ap = posixpath.join(ap, ent.filename)
                stack.append((child_rp, child_ap))
        else:
            with sftp.open(rp, 'rb') as f:
                data = f.read()
            ti = tarfile.TarInfo(name=ap)
            ti.size = len(data)
            ti.mode = st.st_mode & 0o777
            tf.addfile(ti, io.BytesIO(data))

with tarfile.open(out_path, 'w:gz') as tf:
    add_tree(tf, '/usr/local/lighthouse/softwares/cloudreve', 'cloudreve/cloudreve')
    add_tree(tf, '/usr/local/lighthouse/softwares/aria2/conf', 'aria2/conf')
    if exists('/www/server/panel/vhost/nginx/cloudreve.local.conf'):
        add_file(tf, '/www/server/panel/vhost/nginx/cloudreve.local.conf', 'nginx/cloudreve.local.conf')
    if exists('/usr/lib/systemd/system/cloudreve.service'):
        add_file(tf, '/usr/lib/systemd/system/cloudreve.service', 'systemd/cloudreve.service')
    stdin, stdout, stderr = client.exec_command("if mysql -Nse \"SHOW DATABASES LIKE 'cloudreve';\" 2>/dev/null | grep -q cloudreve; then mysqldump --single-transaction --quick cloudreve; fi", timeout=120)
    sql = stdout.read()
    if sql:
        ti = tarfile.TarInfo(name='db/cloudreve.sql')
        ti.size = len(sql)
        ti.mode = 0o600
        tf.addfile(ti, io.BytesIO(sql))

client.close()
PY

python3 "$PYTHON_SCRIPT" "$OLD_HOST" "$OLD_USER" "$OLD_PASSWORD" "$EXPORT_TGZ"
echo "[+] 已从旧服务器抓取迁移包: $EXPORT_TGZ"

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

chmod +x /usr/local/lighthouse/softwares/cloudreve/cloudreve 2>/dev/null || true

mkdir -p /etc/nginx/conf.d
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default 2>/dev/null || true
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

mysql -uroot <<'EOF'
CREATE DATABASE IF NOT EXISTS cloudreve CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'cloudreve'@'localhost' IDENTIFIED BY '-Ypu7cR.5M98';
CREATE USER IF NOT EXISTS 'cloudreve'@'127.0.0.1' IDENTIFIED BY '-Ypu7cR.5M98';
ALTER USER 'cloudreve'@'localhost' IDENTIFIED BY '-Ypu7cR.5M98';
ALTER USER 'cloudreve'@'127.0.0.1' IDENTIFIED BY '-Ypu7cR.5M98';
GRANT ALL PRIVILEGES ON cloudreve.* TO 'cloudreve'@'localhost';
GRANT ALL PRIVILEGES ON cloudreve.* TO 'cloudreve'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

if [[ -f "$STAGE_DIR/db/cloudreve.sql" ]]; then
  mysql -uroot cloudreve < "$STAGE_DIR/db/cloudreve.sql" || true
fi

systemctl daemon-reload
if [[ -f /usr/local/lighthouse/softwares/aria2/conf/aria2.conf ]]; then
  cat > /etc/systemd/system/aria2.service <<'EOF'
[Unit]
Description=aria2
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/aria2c --conf-path=/usr/local/lighthouse/softwares/aria2/conf/aria2.conf
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now aria2 || true
fi
systemctl enable --now cloudreve || true
nginx -t && systemctl reload nginx || true
systemctl restart cloudreve || true

echo "[+] 新服务器直连旧服务器恢复完成"
echo "[+] 已自动处理：paramiko依赖、cloudreve执行权限、Debian默认nginx站点冲突、数据库账号权限、aria2 service。"
echo "[!] 后续仍需确认：域名、证书、Cloudreve外链设置。"
