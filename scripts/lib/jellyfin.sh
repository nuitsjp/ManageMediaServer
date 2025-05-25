#!/bin/bash
# Jellyfin専用ライブラリ（Jellyfinアプリケーション特化機能）

# Jellyfin全体セットアップ
setup_jellyfin() {
    log_info "=== Jellyfin セットアップ開始 ==="
    
    create_jellyfin_directories
    configure_jellyfin_compose
    validate_jellyfin_setup
    
    log_success "=== Jellyfin セットアップ完了 ==="
}

# Jellyfinディレクトリ作成
create_jellyfin_directories() {
    local jellyfin_dirs=(
        "$DATA_ROOT/jellyfin/config"
        "$DATA_ROOT/jellyfin/movies"
    )
    
    for dir in "${jellyfin_dirs[@]}"; do
        ensure_dir_exists "$dir"
    done
    
    # Docker Compose構造作成
    create_docker_compose_structure "jellyfin"
}

# Jellyfin Compose設定確認
configure_jellyfin_compose() {
    local compose_file="$PROJECT_ROOT/docker/jellyfin/docker-compose.yml"
    
    if [ ! -f "$compose_file" ]; then
        log_error "Jellyfin用Docker Composeファイルが見つかりません: $compose_file"
        log_info "公式のdocker-compose.ymlファイルを配置してください"
        log_info "参考: https://jellyfin.org/docs/general/installation/container"
        return 1
    fi
    
    log_success "Jellyfin Docker Composeファイルが確認できました"
}

# Jellyfin用.envファイル生成（実際は何もしない）
generate_jellyfin_env() {
    # Jellyfinは.envファイルを使用しないため、何もしない
    log_info "Jellyfin設定: 公式Docker Composeファイルを使用（.env不要）"
    log_info "設定変更が必要な場合は docker/jellyfin/docker-compose.yml を直接編集してください"
}

# Jellyfin設定検証
validate_jellyfin_setup() {
    local compose_file="$PROJECT_ROOT/docker/jellyfin/docker-compose.yml"
    
    if [ ! -f "$compose_file" ]; then
        log_error "Jellyfin Docker Composeファイルが見つかりません: $compose_file"
    fi
    
    # 必要なディレクトリの存在確認
    if [ ! -d "$DATA_ROOT/jellyfin/config" ]; then
        log_error "Jellyfin設定ディレクトリが見つかりません: $DATA_ROOT/jellyfin/config"
    fi
    
    if [ ! -d "$DATA_ROOT/jellyfin/movies" ]; then
        log_error "Jellyfinメディアディレクトリが見つかりません: $DATA_ROOT/jellyfin/movies"
    fi
    
    log_success "Jellyfin設定が正常に検証されました"
}
