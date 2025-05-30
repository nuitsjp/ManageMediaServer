#!/bin/bash
# Jellyfin専用ライブラリ（Jellyfinアプリケーション特化機能）

# Jellyfin全体セットアップ
setup_jellyfin() {
    log_info "=== Jellyfin セットアップ開始 ==="
    
    create_jellyfin_directories
    validate_jellyfin_setup
    
    log_success "=== Jellyfin セットアップ完了 ==="
}

# Jellyfinディレクトリ作成
create_jellyfin_directories() {
    local jellyfin_dirs=(
        "$PROJECT_ROOT/docker/jellyfin"
        "$DATA_ROOT/jellyfin/config"
        "$DATA_ROOT/jellyfin/cache"
        "$DATA_ROOT/jellyfin/movies"
        "$DATA_ROOT/jellyfin/tv"
    )
    
    for dir in "${jellyfin_dirs[@]}"; do
        ensure_dir_exists "$dir"
    done
    
    log_debug "Jellyfin用ディレクトリ構造を準備しました"
}

# Jellyfin設定検証
validate_jellyfin_setup() {
    local compose_file="$PROJECT_ROOT/docker/jellyfin/docker-compose.yml"
    local source_compose="/home/ubuntu/repos/ManageMediaServer/docker/jellyfin/docker-compose.yml"
    
    # Docker Composeファイル確認・コピー
    if [ ! -f "$compose_file" ]; then
        log_info "Jellyfin用Docker Composeファイルをコピー中..."
        if [ -f "$source_compose" ]; then
            cp "$source_compose" "$compose_file"
            log_success "Docker Composeファイルをコピーしました"
        else
            log_error "コピー元のDocker Composeファイルが見つかりません: $source_compose"
            return 1
        fi
    fi
    
    log_success "Jellyfin設定が正常に検証されました"
}
