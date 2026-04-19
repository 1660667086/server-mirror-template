#!/usr/bin/env bash
set -euo pipefail

BACKUP_REPO="${1:-}"
BRANCH="${2:-main}"
WORKDIR="/root/server-mirror-repo-restore"
ARCHIVE_PATH="/root/server-mirror-export.tar.gz"
SCRIPT_BASE_URL="${SCRIPT_BASE_URL:-https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror}"

usage() {
  echo "用法: GITHUB_TOKEN=token bash restore-from-git-repo.sh <backup_repo> [branch]"
  echo "示例: GITHUB_TOKEN=token bash restore-from-git-repo.sh yourname/server-mirror-backup main"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[!] 缺少命令: $cmd"
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

require_cmd bash
require_cmd curl
require_cmd git
require_cmd python3
require_cmd sha256sum

rm -rf "$WORKDIR"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  git clone --depth=1 --branch "$BRANCH" "https://x-access-token:${GITHUB_TOKEN}@github.com/${BACKUP_REPO}.git" "$WORKDIR"
else
  git clone --depth=1 --branch "$BRANCH" "https://github.com/${BACKUP_REPO}.git" "$WORKDIR"
fi

if [[ ! -f "$WORKDIR/snapshot/MANIFEST.txt" ]]; then
  echo "[!] 未找到快照清单文件: $WORKDIR/snapshot/MANIFEST.txt"
  exit 1
fi

PART_COUNT="$(find "$WORKDIR/snapshot" -type f -name 'server-mirror-export.tar.gz.part.*' | wc -l | tr -d ' ')"
if [[ "$PART_COUNT" == "0" ]]; then
  echo "[!] 未找到迁移包分片"
  exit 1
fi

echo "[+] 从 Git 仓库重组迁移包"
find "$WORKDIR/snapshot" -type f -name 'server-mirror-export.tar.gz.part.*' | LC_ALL=C sort | xargs cat > "$ARCHIVE_PATH"

EXPECTED_SHA256="$(awk -F= '/^archive_sha256=/{print $2}' "$WORKDIR/snapshot/MANIFEST.txt")"
if [[ -n "$EXPECTED_SHA256" ]]; then
  ACTUAL_SHA256="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
  if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "[!] 迁移包校验失败"
    echo "[!] expected: $EXPECTED_SHA256"
    echo "[!] actual:   $ACTUAL_SHA256"
    exit 1
  fi
fi

IMPORT_HELPER="$(fetch_helper)"
bash "$IMPORT_HELPER" "$ARCHIVE_PATH"
