#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE_DIR"

if [[ ! -f .env ]]; then
  cp env.example .env
  echo "[!] 已生成 .env，请先编辑后再重跑。"
  echo "    nano .env"
  exit 1
fi

bash init-server.sh
bash deploy-cloudreve.sh
bash deploy-nginx.sh

echo "[+] 安装完成"
