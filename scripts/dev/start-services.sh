#!/bin/bash
# 開発サービス一括起動
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/env-loader.sh"

log_info "=== 開発サービス起動 ==="

cd "$PROJECT_ROOT"

# Immichサービス起動
log_info "Immichを起動中..."
docker compose -f docker/immich/docker-compose.yml up -d

# Jellyfinサービス起動
log_info "Jellyfinを起動中..."
docker compose -f docker/jellyfin/docker-compose.yml up -d

log_success "サービス起動完了"
log_info "Immich: http://localhost:2283"
log_info "Jellyfin: http://localhost:8096"
