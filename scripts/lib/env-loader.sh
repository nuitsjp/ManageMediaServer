#!/bin/bash
# DEPRECATED: この機能は config.sh に統合されました
# 新しいスクリプトでは config.sh を使用してください

echo "[WARNING] env-loader.sh は非推奨です。config.sh を使用してください。" >&2

# 後方互換性のため config.sh を読み込み
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
