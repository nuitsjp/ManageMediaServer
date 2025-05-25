#!/bin/bash
# 統合設定管理ライブラリ（環境変数読み込み + アプリケーション設定）

# 環境変数読み込み関数（env-loader.shから統合）
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

# 設定ファイル展開機能（auto-setup.shから移動）

# 設定ファイル展開
deploy_config_files() {
    log_info "=== 設定ファイル展開 ==="
    
    # Docker Composeファイル作成
    create_docker_compose_files
    
    # シェル環境に環境変数設定を追加
    setup_shell_environment
    
    log_success "設定ファイル展開完了"
}

# Docker Composeファイル作成
create_docker_compose_files() {
    local env_type=$(detect_environment)
    
    log_info "Docker Composeファイルを作成中..."
    
    # 統一パス構成に基づいて作成
    # アプリケーション層のセットアップに委譲
    log_success "Docker Composeファイル作成完了"
}

# シェル環境設定
setup_shell_environment() {
    local env_type=$(detect_environment)
    local env_setup_file="$HOME/.media-server-env"
    
    # 環境変数設定ファイル作成
    cat > "$env_setup_file" << EOF
# MediaServer環境変数設定
# 自動生成日時: $(date '+%Y-%m-%d %H:%M:%S')

export PROJECT_ROOT="$PROJECT_ROOT"
export DATA_ROOT="$DATA_ROOT"
export BACKUP_ROOT="$BACKUP_ROOT"
export MEDIA_SERVER_ENV="$env_type"
EOF
    
    # .bashrcに追加（既に存在しない場合のみ）
    if ! grep -q "media-server-env" "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" << EOF

# MediaServer環境変数設定
if [ -f "\$HOME/.media-server-env" ]; then
    source "\$HOME/.media-server-env"
fi
EOF
        log_info "環境変数設定を .bashrc に追加しました"
    fi
    
    # 開発環境用の自動起動設定は統一構成に対応
    if [ "$env_type" = "dev" ] && ! grep -q "docker compose -f docker/immich/docker-compose.yml up -d" "$HOME/.bashrc"; then
        cat >> "$HOME/.bashrc" << 'EOF'

# 開発環境起動時のサービス自動起動
if [ -f "$PROJECT_ROOT/docker/immich/docker-compose.yml" ]; then
    (cd "$PROJECT_ROOT" && docker compose -f docker/immich/docker-compose.yml up -d)
    (cd "$PROJECT_ROOT" && docker compose -f docker/jellyfin/docker-compose.yml up -d)
fi
EOF
        log_info "開発環境サービス自動起動設定を .bashrc に追加しました"
    fi
    
    # 現在のセッションに環境変数を反映
    source "$env_setup_file"
}

# 初期化時に自動実行（env-loaderから移動）
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    # sourceされた場合のみ実行
    load_environment
fi
