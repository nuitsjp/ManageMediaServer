#!/bin/bash
# 開発サービス一括停止
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/common.sh"

log_info "=== 開発サービス停止 ==="

cd "$PROJECT_ROOT"

# Jellyfinサービス停止
log_info "Jellyfinを停止中..."
docker compose -f docker/jellyfin/docker-compose.yml down

# Immichサービス停止
log_info "Immichを停止中..."
docker compose -f docker/immich/docker-compose.yml down

log_success "サービス停止完了"
