#!/usr/bin/env bash
set -euo pipefail
TMP_SCRIPT=/tmp/migrate-direct.sh
curl -fsSL https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror/migrate-direct.sh -o "$TMP_SCRIPT"
sed -i '1s/^\xEF\xBB\xBF//' "$TMP_SCRIPT"
sed -i 's/\r$//' "$TMP_SCRIPT"
chmod +x "$TMP_SCRIPT"
exec bash "$TMP_SCRIPT" "$@"
