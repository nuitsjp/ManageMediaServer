#!/bin/bash
# Immich専用ライブラリ（Immichアプリケーション特化機能）

# Immich全体セットアップ
setup_immich() {
    log_info "=== Immich セットアップ開始 ==="
    
    create_immich_directories
    download_immich_files
    configure_immich_environment
    validate_immich_setup
    
    log_success "=== Immich セットアップ完了 ==="
}

# Immichディレクトリ作成
create_immich_directories() {
    local immich_dirs=(
        "$PROJECT_ROOT/docker/immich"
        "$DATA_ROOT/immich/upload"
        "$DATA_ROOT/immich/external"
        "$DATA_ROOT/immich/postgres"
    )
    
    for dir in "${immich_dirs[@]}"; do
        ensure_dir_exists "$dir"
    done
    
    log_debug "Immich用ディレクトリ構造を準備しました"
}

# Immich公式ファイルダウンロード
download_immich_files() {
    local compose_file="$PROJECT_ROOT/docker/immich/docker-compose.yml"
    local env_file="$PROJECT_ROOT/docker/immich/.env"
    local compose_dir="$(dirname "$compose_file")"
    
    # 既存ファイルがない場合、または強制更新の場合
    if [ ! -f "$compose_file" ] || [ ! -f "$env_file" ] || [ "${FORCE:-false}" = "true" ]; then
        log_info "Immich公式設定ファイルをダウンロード中..."
        
        # 作業ディレクトリに移動
        cd "$compose_dir"
        
        # 公式ファイルダウンロード
        if wget -O docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml; then
            log_success "docker-compose.yml をダウンロードしました"
        else
            log_error "docker-compose.yml のダウンロードに失敗しました"
            return 1
        fi
        
        if wget -O .env https://github.com/immich-app/immich/releases/latest/download/example.env; then
            log_success ".env をダウンロードしました"
        else
            log_error ".env のダウンロードに失敗しました"
            return 1
        fi
        
        log_success "Immich設定ファイルの準備が完了しました"
    else
        log_info "Immich設定ファイルは既に存在します"
    fi
}

# Immich .envファイルの環境調整
configure_immich_environment() {
    local env_file="$PROJECT_ROOT/docker/immich/.env"
    local compose_file="$PROJECT_ROOT/docker/immich/docker-compose.yml"
    local env_type=$(detect_environment)
    
    log_info "Immich .envファイルを環境に応じて設定中..."
    
    # 環境変数のパスを設定
    sed -i "s|UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${DATA_ROOT}/immich/upload|" "$env_file"
    sed -i "s|DB_DATA_LOCATION=.*|DB_DATA_LOCATION=${DATA_ROOT}/immich/postgres|" "$env_file"
    
    # EXTERNAL_PATH行を追加（存在しない場合）
    if ! grep -q "EXTERNAL_PATH" "$env_file"; then
        echo "" >> "$env_file"
        echo "# External library path for read-only access to existing photo collections" >> "$env_file"
        echo "EXTERNAL_PATH=${DATA_ROOT}/immich/external" >> "$env_file"
    else
        sed -i "s|EXTERNAL_PATH=.*|EXTERNAL_PATH=${DATA_ROOT}/immich/external|" "$env_file"
    fi
    
    # docker-compose.ymlに外部ライブラリパスを追加
    if ! grep -q "EXTERNAL_PATH" "$compose_file"; then
        log_info "外部ライブラリパスをdocker-compose.ymlに追加中..."
        sed -i '/- \/etc\/localtime:\/etc\/localtime:ro/a\      # External library support\n      - ${EXTERNAL_PATH:-/tmp/empty}:/usr/src/app/external:ro' "$compose_file"
        log_success "外部ライブラリパスを追加しました"
    fi
    
    log_success "Immich .envファイルの設定が完了しました"
}

# Immich設定検証
validate_immich_setup() {
    local compose_file="$PROJECT_ROOT/docker/immich/docker-compose.yml"
    local env_file="$PROJECT_ROOT/docker/immich/.env"
    
    if [ ! -f "$compose_file" ]; then
        log_error "Immich Docker Composeファイルが見つかりません: $compose_file"
    fi
    
    if [ ! -f "$env_file" ]; then
        log_error "Immich .envファイルが見つかりません: $env_file"
    fi
    
    log_success "Immich設定が正常に検証されました"
}
