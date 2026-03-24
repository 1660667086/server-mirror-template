#!/usr/bin/env bash
set -euo pipefail

if [[ -f .env ]]; then
  set -a
  source ./.env
  set +a
fi

if command -v apt >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt install -y curl wget unzip tar nginx mariadb-server ufw
  systemctl enable --now nginx mariadb
  ufw allow 22/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw --force enable || true
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl wget unzip tar nginx mariadb-server firewalld
  systemctl enable --now nginx mariadb firewalld
  firewall-cmd --permanent --add-service=ssh || true
  firewall-cmd --permanent --add-service=http || true
  firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y epel-release || true
  yum install -y curl wget unzip tar nginx mariadb-server firewalld
  systemctl enable --now nginx mariadb firewalld
  firewall-cmd --permanent --add-service=ssh || true
  firewall-cmd --permanent --add-service=http || true
  firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
else
  echo "[!] 不支持的系统包管理器"
  exit 1
fi

echo "[+] 基础依赖安装完成"
