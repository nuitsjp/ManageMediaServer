#!/bin/bash
# 設定管理ライブラリ（アプリケーション固有設定）

# 前提: env-loader.shで基本パス変数が設定済み

# Docker設定
export INSTALL_DOCKER_COMPOSE_STANDALONE="${INSTALL_DOCKER_COMPOSE_STANDALONE:-false}"

# Immich詳細設定
export IMMICH_UPLOAD_LOCATION="${IMMICH_DIR_PATH}/library"
export IMMICH_EXTERNAL_LIBRARY_PATH="${IMMICH_DIR_PATH}/external"

# Jellyfin詳細設定
export JELLYFIN_CACHE_PATH="${DATA_ROOT}/jellyfin/cache"

# Cloudflare詳細設定
export CLOUDFLARE_CONFIG_PATH="${DATA_ROOT}/config/cloudflared"

# rclone詳細設定
export RCLONE_LOG_PATH="${DATA_ROOT}/config/rclone/logs"

# systemd設定（本番環境のみ）
if [ "$(detect_environment 2>/dev/null)" = "prod" ]; then
    export SYSTEMD_CONFIG_PATH="/etc/systemd/system"
fi
