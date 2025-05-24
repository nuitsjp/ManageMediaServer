#!/bin/bash
# 環境変数読み込みライブラリ
# 開発・本番環境の物理パス差分を吸収

# 環境判定関数
detect_environment() {
    if grep -qE "(Microsoft|WSL)" /proc/version 2>/dev/null; then
        echo "dev"
    elif [ -f /etc/os-release ] && grep -q "Ubuntu" /etc/os-release; then
        echo "prod"
    else
        echo "unknown"
    fi
}

# 環境変数読み込み関数
load_environment() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="${script_dir}/../.."
    local env_type=$(detect_environment)
    
    # 共通設定読み込み
    local common_config="${project_root}/config/env/common.env"
    if [ -f "$common_config" ]; then
        source "$common_config"
    fi
    
    # 環境別設定読み込み
    local env_config="${project_root}/config/env/${env_type}.env"
    if [ -f "$env_config" ]; then
        source "$env_config"
        export PROJECT_ROOT DATA_ROOT BACKUP_ROOT COMPOSE_FILE
        export IMMICH_DIR_PATH JELLYFIN_CONFIG_PATH JELLYFIN_MEDIA_PATH RCLONE_CONFIG_PATH
    else
        echo "[ERROR] 設定ファイルが見つかりません: $env_config" >&2
        exit 1
    fi
}

# 初期化時に自動実行
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    # sourceされた場合のみ実行
    load_environment
fi
