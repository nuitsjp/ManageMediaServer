#!/bin/bash
# filepath: /mnt/d/ManageMediaServer/scripts/lib/config.sh
#
# 設定管理ライブラリ - 環境変数、設定ファイル管理

# デフォルト設定値
DEFAULT_MEDIA_DIR="/mnt/mediaserver"
DEFAULT_PHOTOS_DIR="${DEFAULT_MEDIA_DIR}/photos"
DEFAULT_VIDEOS_DIR="${DEFAULT_MEDIA_DIR}/videos" 
DEFAULT_MUSIC_DIR="${DEFAULT_MEDIA_DIR}/music"
DEFAULT_BACKUPS_DIR="${DEFAULT_MEDIA_DIR}/backups"
DEFAULT_CONFIG_DIR="${DEFAULT_MEDIA_DIR}/config"

# Immich関連設定
DEFAULT_IMMICH_CONFIG_DIR="${DEFAULT_CONFIG_DIR}/immich"
DEFAULT_IMMICH_DB_PASSWORD="postgres_password"
DEFAULT_IMMICH_PORT="2283"
DEFAULT_IMMICH_UPLOAD_LOCATION="${DEFAULT_PHOTOS_DIR}/uploads"

# Jellyfin関連設定
DEFAULT_JELLYFIN_CONFIG_DIR="${DEFAULT_CONFIG_DIR}/jellyfin"
DEFAULT_JELLYFIN_PORT="8096"
DEFAULT_JELLYFIN_CACHE_DIR="${DEFAULT_CONFIG_DIR}/jellyfin/cache"

# rclone関連設定
DEFAULT_RCLONE_CONFIG_DIR="${DEFAULT_CONFIG_DIR}/rclone" 
DEFAULT_RCLONE_CONFIG_FILE="${DEFAULT_RCLONE_CONFIG_DIR}/rclone.conf"

# Cloudflare関連設定
DEFAULT_CLOUDFLARE_CONFIG_DIR="${DEFAULT_CONFIG_DIR}/cloudflare"
DEFAULT_CLOUDFLARE_TUNNEL_CONFIG="${DEFAULT_CLOUDFLARE_CONFIG_DIR}/tunnel_config.yaml"

# ネットワーク設定
DEFAULT_USE_CLOUDFLARE_TUNNEL="true"
DEFAULT_LOCAL_DOMAIN="media.local"

# 設定ファイルパス
CONFIG_ENV_FILE="${PROJECT_ROOT}/config/.env"

# 設定の初期化
initialize_config() {
    local category="$1"
    
    # 現在は最小限の実装
    log_info "設定を初期化しています..."
    
    # 設定ディレクトリの作成
    mkdir -p "${DEFAULT_CONFIG_DIR}"
    
    # .envファイルが存在しない場合は作成
    if [[ ! -f "${CONFIG_ENV_FILE}" ]]; then
        log_info "設定ファイルを作成: ${CONFIG_ENV_FILE}"
        
        # 親ディレクトリ作成
        mkdir -p "$(dirname "${CONFIG_ENV_FILE}")"
        
        # .envファイル作成
        cat > "${CONFIG_ENV_FILE}" << EOF
# MediaServer 設定ファイル
# 自動生成: $(date '+%Y-%m-%d %H:%M:%S')

# メディアディレクトリ
MEDIA_DIR=${DEFAULT_MEDIA_DIR}
PHOTOS_DIR=${DEFAULT_PHOTOS_DIR}
VIDEOS_DIR=${DEFAULT_VIDEOS_DIR}
MUSIC_DIR=${DEFAULT_MUSIC_DIR}
BACKUPS_DIR=${DEFAULT_BACKUPS_DIR}
CONFIG_DIR=${DEFAULT_CONFIG_DIR}

# Immich設定
IMMICH_CONFIG_DIR=${DEFAULT_IMMICH_CONFIG_DIR}
IMMICH_DB_PASSWORD=${DEFAULT_IMMICH_DB_PASSWORD}
IMMICH_PORT=${DEFAULT_IMMICH_PORT}
IMMICH_UPLOAD_LOCATION=${DEFAULT_IMMICH_UPLOAD_LOCATION}

# Jellyfin設定 
JELLYFIN_CONFIG_DIR=${DEFAULT_JELLYFIN_CONFIG_DIR}
JELLYFIN_PORT=${DEFAULT_JELLYFIN_PORT}
JELLYFIN_CACHE_DIR=${DEFAULT_JELLYFIN_CACHE_DIR}

# rclone設定
RCLONE_CONFIG_DIR=${DEFAULT_RCLONE_CONFIG_DIR}
RCLONE_CONFIG_FILE=${DEFAULT_RCLONE_CONFIG_FILE}

# Cloudflare設定
CLOUDFLARE_CONFIG_DIR=${DEFAULT_CLOUDFLARE_CONFIG_DIR}
CLOUDFLARE_TUNNEL_CONFIG=${DEFAULT_CLOUDFLARE_TUNNEL_CONFIG}
USE_CLOUDFLARE_TUNNEL=${DEFAULT_USE_CLOUDFLARE_TUNNEL}
LOCAL_DOMAIN=${DEFAULT_LOCAL_DOMAIN}
EOF
    else
        log_info "既存の設定ファイルを使用: ${CONFIG_ENV_FILE}"
    fi
    
    # 設定の読み込み
    load_config
}

# 設定の読み込み
load_config() {
    if [[ -f "${CONFIG_ENV_FILE}" ]]; then
        log_info "設定ファイルを読み込み: ${CONFIG_ENV_FILE}"
        # shellcheckの警告を抑制するためにsourceではなく.を使用
        # shellcheck source=/dev/null
        . "${CONFIG_ENV_FILE}"
    else
        log_warning "設定ファイルが見つかりません。デフォルト値を使用します。"
    fi
}

# 設定値の取得（デフォルト値を使用）
get_config_value() {
    local key="$1"
    local default_value="$2"
    
    local value
    # 変数が設定されているか確認し、設定されていれば使用、なければデフォルト値を使用
    # 間接的な変数参照を使用
    value="${!key:-$default_value}"
    echo "$value"
}

# 設定値の保存
save_config_value() {
    local key="$1"
    local value="$2"
    
    # 設定ファイルが存在しない場合は作成
    if [[ ! -f "${CONFIG_ENV_FILE}" ]]; then
        initialize_config "all"
    fi
    
    # 既存のキーを更新または新しいキーを追加
    if grep -q "^${key}=" "${CONFIG_ENV_FILE}"; then
        # 既存のキーを更新
        sed -i "s|^${key}=.*|${key}=${value}|" "${CONFIG_ENV_FILE}"
    else
        # 新しいキーを追加
        echo "${key}=${value}" >> "${CONFIG_ENV_FILE}"
    fi
    
    # 設定を再読み込み
    load_config
}
