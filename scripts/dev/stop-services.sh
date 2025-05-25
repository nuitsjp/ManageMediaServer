#!/bin/bash
# 開発サービス一括停止
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/common.sh"

log_info "=== 開発サービス停止 ==="

cd "$PROJECT_ROOT"

# Docker権限の一時的な解決
USE_SUDO=""
if ! docker info >/dev/null 2>&1; then
    log_warning "Docker権限がありません。sudoを使用します"
    USE_SUDO="sudo"
fi

# Jellyfinサービス停止
log_info "Jellyfinを停止中..."
$USE_SUDO docker compose -f docker/jellyfin/docker-compose.yml down

# Immichサービス停止
log_info "Immichを停止中..."
$USE_SUDO docker compose -f docker/immich/docker-compose.yml down

log_success "サービス停止完了"
