#!/usr/bin/env bash
set -euo pipefail

BACKUP_REPO="${1:-}"
BRANCH="${2:-main}"
CHUNK_SIZE_MB="${CHUNK_SIZE_MB:-90}"
WORKDIR="/root/server-mirror-git-repo"
ARCHIVE_PATH="/root/server-mirror-export/server-mirror-export.tar.gz"
SNAPSHOT_DIR="$WORKDIR/snapshot"
SCRIPT_BASE_URL="${SCRIPT_BASE_URL:-https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror}"

usage() {
  echo "用法: GITHUB_TOKEN=token bash publish-to-git-repo.sh <backup_repo> [branch]"
  echo "示例: GITHUB_TOKEN=token bash publish-to-git-repo.sh yourname/server-mirror-backup main"
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
require_cmd git
require_cmd python3
require_cmd split
require_cmd sha256sum

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
  echo "[!] 请先改成 private，再重新执行。不要把数据库和配置推到公开仓库。"
  exit 1
fi

echo "[+] 准备本地 git 工作目录"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
git init "$WORKDIR" >/dev/null
git -C "$WORKDIR" remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${BACKUP_REPO}.git"

if git -C "$WORKDIR" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  git -C "$WORKDIR" fetch --depth=1 origin "$BRANCH"
  git -C "$WORKDIR" checkout -B "$BRANCH" "origin/$BRANCH"
else
  git -C "$WORKDIR" checkout -B "$BRANCH"
fi

find "$WORKDIR" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
mkdir -p "$SNAPSHOT_DIR"

echo "[+] 切片迁移包并写入仓库"
split -b "${CHUNK_SIZE_MB}m" -d -a 4 "$ARCHIVE_PATH" "$SNAPSHOT_DIR/server-mirror-export.tar.gz.part."

ARCHIVE_SHA256="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
ARCHIVE_SIZE="$(wc -c < "$ARCHIVE_PATH" | tr -d ' ')"
PART_COUNT="$(find "$SNAPSHOT_DIR" -type f -name 'server-mirror-export.tar.gz.part.*' | wc -l | tr -d ' ')"

cat > "$SNAPSHOT_DIR/MANIFEST.txt" <<EOF
repo=${BACKUP_REPO}
branch=${BRANCH}
exported_at=$(date -Is)
hostname=$(hostname)
archive_name=server-mirror-export.tar.gz
archive_size=${ARCHIVE_SIZE}
archive_sha256=${ARCHIVE_SHA256}
part_count=${PART_COUNT}
chunk_size_mb=${CHUNK_SIZE_MB}
EOF

cat > "$WORKDIR/README.md" <<'EOF'
# Server Mirror Backup

这个仓库用于保存服务器迁移快照。

- `snapshot/server-mirror-export.tar.gz.part.*`：迁移包分片
- `snapshot/MANIFEST.txt`：快照元数据

恢复时在新服务器执行：

```bash
export GITHUB_TOKEN='你的token'
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror/restore-from-git-repo.sh) YOUR_REPO main
```
EOF

git -C "$WORKDIR" add .
git -C "$WORKDIR" -c user.name="Codex Backup" -c user.email="codex-backup@users.noreply.github.com" commit -m "Update server mirror snapshot $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null
git -C "$WORKDIR" push -u origin "$BRANCH"

echo "[+] 已推送到 Git 仓库: ${BACKUP_REPO}"
echo "[+] 在新服务器执行:"
echo "    export GITHUB_TOKEN='你的token'"
echo "    bash <(curl -fsSL ${SCRIPT_BASE_URL}/restore-from-git-repo.sh) ${BACKUP_REPO} ${BRANCH}"
echo "[!] 这种方式适合中小体积备份。若备份很大，请优先用 Release 或对象存储。"
