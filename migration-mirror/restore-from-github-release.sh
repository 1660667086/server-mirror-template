#!/usr/bin/env bash
set -euo pipefail

BACKUP_REPO="${1:-}"
RELEASE_TAG="${2:-server-mirror-latest}"
ASSET_NAME="${3:-server-mirror-export.tar.gz}"
DOWNLOAD_PATH="/root/${ASSET_NAME}"
SCRIPT_BASE_URL="${SCRIPT_BASE_URL:-https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror}"

usage() {
  echo "用法: GITHUB_TOKEN=token bash restore-from-github-release.sh <backup_repo> [release_tag] [asset_name]"
  echo "示例: GITHUB_TOKEN=token bash restore-from-github-release.sh yourname/server-mirror-backup server-mirror-latest"
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
require_cmd python3

API_BASE="https://api.github.com/repos/${BACKUP_REPO}"
TOKEN_HEADERS=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  TOKEN_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi
META_HEADERS=("${TOKEN_HEADERS[@]}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
DOWNLOAD_HEADERS=("${TOKEN_HEADERS[@]}" -H "Accept: application/octet-stream" -H "X-GitHub-Api-Version: 2022-11-28")

echo "[+] 获取 GitHub Release: $RELEASE_TAG"
release_tmp="$(mktemp)"
http_code="$(curl -sS -o "$release_tmp" -w '%{http_code}' "${META_HEADERS[@]}" "$API_BASE/releases/tags/$RELEASE_TAG")"
if [[ "$http_code" != "200" ]]; then
  echo "[!] 获取 Release 失败，HTTP 状态码: $http_code"
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "[!] 如果备份仓库是私有仓库，请先设置 GITHUB_TOKEN。"
  fi
  cat "$release_tmp"
  rm -f "$release_tmp"
  exit 1
fi
RELEASE_JSON="$(cat "$release_tmp")"
rm -f "$release_tmp"

ASSET_API_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys
asset_name = sys.argv[1]
for asset in json.load(sys.stdin).get("assets", []):
    if asset.get("name") == asset_name:
        print(asset["url"])
        break
' "$ASSET_NAME")"
if [[ -z "$ASSET_API_URL" ]]; then
  echo "[!] 没找到资源文件: $ASSET_NAME"
  echo "[!] 当前 Release 里的资源如下:"
  printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys
for asset in json.load(sys.stdin).get("assets", []):
    print(asset.get("name", ""))
'
  exit 1
fi

echo "[+] 从 GitHub 下载迁移包"
curl -fsSL -L \
  "${DOWNLOAD_HEADERS[@]}" \
  -o "$DOWNLOAD_PATH" \
  "$ASSET_API_URL"

IMPORT_HELPER="$(fetch_helper)"
bash "$IMPORT_HELPER" "$DOWNLOAD_PATH"
