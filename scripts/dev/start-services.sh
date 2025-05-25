#!/bin/bash
# 開発サービス一括起動
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/config.sh"

log_info "=== 開発サービス起動 ==="

cd "$PROJECT_ROOT"

# Docker権限の一時的な解決
USE_SUDO=""
if ! docker info >/dev/null 2>&1; then
    log_warning "Docker権限がありません。sudoを使用します"
    USE_SUDO="sudo"
fi

# Immichサービス起動
log_info "Immichを起動中..."
$USE_SUDO docker compose -f docker/immich/docker-compose.yml up -d

# Jellyfinサービス起動
log_info "Jellyfinを起動中..."
$USE_SUDO docker compose -f docker/jellyfin/docker-compose.yml up -d

log_success "サービス起動完了"
log_info "Immich: http://localhost:2283"
log_info "Jellyfin: http://localhost:8096"
