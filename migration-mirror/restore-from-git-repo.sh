#!/usr/bin/env bash
set -euo pipefail

BACKUP_REPO="${1:-}"
BRANCH="${2:-main}"
WORKDIR="/root/server-mirror-repo-restore"
ARCHIVE_PATH="/root/server-mirror-export.tar.gz"
SCRIPT_BASE_URL="${SCRIPT_BASE_URL:-https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror}"
DEPLOY_KEY_PATH="${DEPLOY_KEY_PATH:-}"
PKG_MANAGER=""
PKG_UPDATE_DONE=0

usage() {
  echo "用法: GITHUB_TOKEN=token bash restore-from-git-repo.sh <backup_repo> [branch]"
  echo "或:   DEPLOY_KEY_PATH=/root/.ssh/server-mirror-backup-deploy bash restore-from-git-repo.sh <backup_repo> [branch]"
  echo "示例: GITHUB_TOKEN=token bash restore-from-git-repo.sh yourname/server-mirror-backup main"
  echo "示例: DEPLOY_KEY_PATH=/root/.ssh/server-mirror-backup-deploy bash restore-from-git-repo.sh yourname/server-mirror-backup main"
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  else
    PKG_MANAGER=""
  fi
}

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "[!] 需要 root 或 sudo 权限来自动安装依赖"
    exit 1
  fi
}

install_packages() {
  local packages=("$@")

  if [[ ${#packages[@]} -eq 0 ]]; then
    return 0
  fi

  detect_pkg_manager
  if [[ -z "$PKG_MANAGER" ]]; then
    echo "[!] 无法识别包管理器，请先手动安装: ${packages[*]}"
    exit 1
  fi

  case "$PKG_MANAGER" in
    apt-get)
      if [[ "$PKG_UPDATE_DONE" -eq 0 ]]; then
        run_as_root apt-get update
        PKG_UPDATE_DONE=1
      fi
      run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    dnf)
      run_as_root dnf install -y "${packages[@]}"
      ;;
    yum)
      run_as_root yum install -y "${packages[@]}"
      ;;
    apk)
      run_as_root apk add --no-cache "${packages[@]}"
      ;;
  esac
}

ensure_cmd() {
  local cmd="$1"
  shift || true
  local packages=("$@")

  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  if [[ ${#packages[@]} -eq 0 ]]; then
    packages=("$cmd")
  fi

  echo "[+] 缺少命令 $cmd，尝试自动安装: ${packages[*]}"
  install_packages "${packages[@]}"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[!] 自动安装后仍缺少命令: $cmd"
    exit 1
  fi
}

fetch_helper() {
  local local_helper
  local_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/import-to-new-server.sh"
  if [[ -f "$local_helper" ]]; then
    echo "$local_helper"
    return
  fi

  local tmp_helper="/tmp/import-to-new-server.sh"
  curl -fsSL "$SCRIPT_BASE_URL/import-to-new-server.sh" -o "$tmp_helper"
  sed -i '1s/^\xEF\xBB\xBF//' "$tmp_helper" 2>/dev/null || true
  sed -i 's/\r$//' "$tmp_helper" 2>/dev/null || true
  chmod +x "$tmp_helper"
  echo "$tmp_helper"
}

if [[ -z "$BACKUP_REPO" ]]; then
  usage
  exit 1
fi

ensure_cmd bash bash
ensure_cmd curl curl
ensure_cmd git git
ensure_cmd python3 python3
ensure_cmd sha256sum coreutils

rm -rf "$WORKDIR"

if [[ -n "$DEPLOY_KEY_PATH" ]]; then
  if [[ ! -f "$DEPLOY_KEY_PATH" ]]; then
    echo "[!] 找不到 deploy key: $DEPLOY_KEY_PATH"
    exit 1
  fi
  echo "[+] 使用 deploy key 通过 SSH 拉取仓库"
  GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY_PATH -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
    git clone --depth=1 --branch "$BRANCH" "git@github.com:${BACKUP_REPO}.git" "$WORKDIR"
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  echo "[+] 使用 GITHUB_TOKEN 通过 HTTPS 拉取仓库"
  git clone --depth=1 --branch "$BRANCH" "https://x-access-token:${GITHUB_TOKEN}@github.com/${BACKUP_REPO}.git" "$WORKDIR"
elif [[ -f /root/.ssh/server-mirror-backup-deploy ]]; then
  echo "[+] 检测到默认 deploy key，使用 SSH 拉取仓库"
  GIT_SSH_COMMAND="ssh -i /root/.ssh/server-mirror-backup-deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
    git clone --depth=1 --branch "$BRANCH" "git@github.com:${BACKUP_REPO}.git" "$WORKDIR"
else
  echo "[!] 未提供 GITHUB_TOKEN，也未提供 DEPLOY_KEY_PATH"
  exit 1
fi

MANIFEST_PATH=""
if [[ -f "$WORKDIR/snapshot/MANIFEST.txt" ]]; then
  MANIFEST_PATH="$WORKDIR/snapshot/MANIFEST.txt"
elif [[ -f "$WORKDIR/MANIFEST.txt" ]]; then
  MANIFEST_PATH="$WORKDIR/MANIFEST.txt"
fi

if [[ -f "$WORKDIR/server-mirror-export.tar.gz" ]]; then
  echo "[+] 使用仓库根目录中的迁移包"
  cp -f "$WORKDIR/server-mirror-export.tar.gz" "$ARCHIVE_PATH"
elif [[ -f "$WORKDIR/snapshot/server-mirror-export.tar.gz" ]]; then
  echo "[+] 使用 snapshot 目录中的迁移包"
  cp -f "$WORKDIR/snapshot/server-mirror-export.tar.gz" "$ARCHIVE_PATH"
else
  RAW_PARTS="$(find "$WORKDIR" -maxdepth 2 -type f -name 'server-mirror-export.tar.gz.part.*' | LC_ALL=C sort)"
  B64_PARTS="$(find "$WORKDIR" -maxdepth 2 -type f -name 'server-mirror-export.tar.gz.part.*.b64' | LC_ALL=C sort)"

  if [[ -n "$RAW_PARTS" ]]; then
    echo "[+] 从 Git 仓库重组原始迁移包分片"
    printf '%s\n' "$RAW_PARTS" | xargs cat > "$ARCHIVE_PATH"
  elif [[ -n "$B64_PARTS" ]]; then
    ensure_cmd base64 coreutils
    echo "[+] 从 Git 仓库重组 Base64 迁移包分片"
    printf '%s\n' "$B64_PARTS" | xargs cat | base64 -d > "$ARCHIVE_PATH"
  else
    echo "[!] 未找到迁移包或迁移包分片"
    exit 1
  fi
fi

if [[ -n "$MANIFEST_PATH" ]]; then
  EXPECTED_SHA256="$(awk -F= '/^archive_sha256=/{print $2}' "$MANIFEST_PATH")"
  if [[ -n "$EXPECTED_SHA256" ]]; then
    ACTUAL_SHA256="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
      echo "[!] 迁移包校验失败"
      echo "[!] expected: $EXPECTED_SHA256"
      echo "[!] actual:   $ACTUAL_SHA256"
      exit 1
    fi
  fi
else
  echo "[!] 未找到 MANIFEST.txt，跳过 SHA256 校验"
fi

IMPORT_HELPER="$(fetch_helper)"
bash "$IMPORT_HELPER" "$ARCHIVE_PATH"
