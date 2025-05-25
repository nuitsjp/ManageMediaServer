#!/bin/bash
# 開発データリセット
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/env-loader.sh"

log_warning "開発データをリセットします"
log_warning "この操作により以下のデータが削除されます:"
log_warning "- Immichライブラリ ($DATA_ROOT/immich)"
log_warning "- Jellyfinライブラリ ($DATA_ROOT/jellyfin)"
log_warning "- 一時ファイル ($DATA_ROOT/temp)"

if ! confirm_action "本当にリセットしますか？"; then
    log_info "リセットをキャンセルしました"
    exit 0
fi

# Docker権限の一時的な解決
USE_SUDO=""
if ! docker info >/dev/null 2>&1; then
    log_warning "Docker権限がありません。sudoを使用します"
    USE_SUDO="sudo"
fi

# サービス停止
log_info "サービスを停止中..."
cd "$(dirname "$SCRIPT_DIR")"
$USE_SUDO docker compose -f docker/jellyfin/docker-compose.yml down 2>/dev/null || true
$USE_SUDO docker compose -f docker/immich/docker-compose.yml down 2>/dev/null || true

# データディレクトリ削除・再作成
log_info "データディレクトリをリセット中..."
rm -rf "$DATA_ROOT/immich/library" "$DATA_ROOT/immich/postgres" "$DATA_ROOT/immich/model-cache"
rm -rf "$DATA_ROOT/jellyfin" "$DATA_ROOT/temp"/*

# ディレクトリ再作成
mkdir -p "$DATA_ROOT/immich/library" "$DATA_ROOT/immich/external"
mkdir -p "$DATA_ROOT/jellyfin/config" "$DATA_ROOT/jellyfin/movies"
mkdir -p "$DATA_ROOT/temp"

log_success "開発データのリセット完了"
log_info "サービス再起動: $SCRIPT_DIR/start-services.sh"
