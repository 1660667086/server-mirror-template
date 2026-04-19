#!/usr/bin/env bash
set -euo pipefail

BACKUP_REPO="${1:-}"
RELEASE_TAG="${2:-server-mirror-latest}"
ASSET_NAME="${3:-server-mirror-export.tar.gz}"
ARCHIVE_PATH="/root/server-mirror-export/server-mirror-export.tar.gz"
SCRIPT_BASE_URL="${SCRIPT_BASE_URL:-https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror}"

usage() {
  echo "用法: GITHUB_TOKEN=token bash publish-to-github-release.sh <backup_repo> [release_tag] [asset_name]"
  echo "示例: GITHUB_TOKEN=token bash publish-to-github-release.sh yourname/server-mirror-backup server-mirror-latest"
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
  local_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/export-old-server.sh"
  if [[ -f "$local_helper" ]]; then
    echo "$local_helper"
    return
  fi

  local tmp_helper="/tmp/export-old-server.sh"
  curl -fsSL "$SCRIPT_BASE_URL/export-old-server.sh" -o "$tmp_helper"
  sed -i '1s/^\xEF\xBB\xBF//' "$tmp_helper" 2>/dev/null || true
  sed -i 's/\r$//' "$tmp_helper" 2>/dev/null || true
  chmod +x "$tmp_helper"
  echo "$tmp_helper"
}

if [[ -z "$BACKUP_REPO" ]]; then
  usage
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "[!] 请先设置 GITHUB_TOKEN"
  exit 1
fi

require_cmd bash
require_cmd curl
require_cmd python3

EXPORT_HELPER="$(fetch_helper)"
bash "$EXPORT_HELPER"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "[!] 导出完成后仍未找到迁移包: $ARCHIVE_PATH"
  exit 1
fi

API_BASE="https://api.github.com/repos/${BACKUP_REPO}"
AUTH_HEADERS=(
  -H "Authorization: Bearer ${GITHUB_TOKEN}"
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
)

echo "[+] 检查备份仓库信息"
REPO_JSON="$(curl -fsSL "${AUTH_HEADERS[@]}" "$API_BASE")"
IS_PRIVATE="$(printf '%s' "$REPO_JSON" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin).get("private") else "false")')"
if [[ "$IS_PRIVATE" != "true" ]]; then
  echo "[!] 备份仓库不是私有仓库，已停止。"
  echo "[!] 请先创建 private 仓库，再重新执行。不要把数据库和配置上传到公开仓库。"
  exit 1
fi

echo "[+] 获取或创建 GitHub Release: $RELEASE_TAG"
release_tmp="$(mktemp)"
http_code="$(curl -sS -o "$release_tmp" -w '%{http_code}' "${AUTH_HEADERS[@]}" "$API_BASE/releases/tags/$RELEASE_TAG")"
if [[ "$http_code" == "200" ]]; then
  RELEASE_JSON="$(cat "$release_tmp")"
elif [[ "$http_code" == "404" ]]; then
  create_payload="$(python3 - "$RELEASE_TAG" <<'PY'
import json, sys
tag = sys.argv[1]
print(json.dumps({
    "tag_name": tag,
    "name": f"Server Mirror {tag}",
    "draft": False,
    "prerelease": False
}))
PY
)"
  RELEASE_JSON="$(curl -fsSL -X POST "${AUTH_HEADERS[@]}" -H "Content-Type: application/json" -d "$create_payload" "$API_BASE/releases")"
else
  echo "[!] 获取 Release 失败，HTTP 状态码: $http_code"
  cat "$release_tmp"
  rm -f "$release_tmp"
  exit 1
fi
rm -f "$release_tmp"

RELEASE_ID="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
OLD_ASSET_ID="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys
asset_name = sys.argv[1]
for asset in json.load(sys.stdin).get("assets", []):
    if asset.get("name") == asset_name:
        print(asset["id"])
        break
' "$ASSET_NAME")"
if [[ -n "$OLD_ASSET_ID" ]]; then
  echo "[+] 删除旧的同名资源: $ASSET_NAME"
  curl -fsSL -X DELETE "${AUTH_HEADERS[@]}" "$API_BASE/releases/assets/$OLD_ASSET_ID" >/dev/null
fi

UPLOAD_NAME="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$ASSET_NAME")"
UPLOAD_URL="https://uploads.github.com/repos/${BACKUP_REPO}/releases/${RELEASE_ID}/assets?name=${UPLOAD_NAME}"

echo "[+] 上传迁移包到 GitHub Release"
UPLOAD_JSON="$(curl -fsSL -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Content-Type: application/gzip" \
  --data-binary @"$ARCHIVE_PATH" \
  "$UPLOAD_URL")"

DOWNLOAD_URL="$(printf '%s' "$UPLOAD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["browser_download_url"])')"

echo "[+] 上传完成"
echo "[+] 下载地址: $DOWNLOAD_URL"
echo "[+] 在新服务器执行:"
echo "    export GITHUB_TOKEN='你的token'"
echo "    bash <(curl -fsSL ${SCRIPT_BASE_URL}/restore-from-github-release.sh) ${BACKUP_REPO} ${RELEASE_TAG} ${ASSET_NAME}"
echo "[!] GitHub Release 单文件仍有大小限制。如果迁移包明显超过 2GB，请改用对象存储中转。"
