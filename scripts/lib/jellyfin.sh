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
        "$DATA_ROOT/jellyfin/movies"
    )
    
    for dir in "${jellyfin_dirs[@]}"; do
        ensure_dir_exists "$dir"
    done
    
    log_debug "Jellyfin用ディレクトリ構造を準備しました"
}

# Jellyfin設定検証
validate_jellyfin_setup() {
    local compose_file="$PROJECT_ROOT/docker/jellyfin/docker-compose.yml"
    
    # Docker Composeファイル確認
    if [ ! -f "$compose_file" ]; then
        log_error "Jellyfin用Docker Composeファイルが見つかりません: $compose_file"
        log_info "公式のdocker-compose.ymlファイルを配置してください"
        log_info "参考: https://jellyfin.org/docs/general/installation/container"
        return 1
    fi
    
    log_success "Jellyfin設定が正常に検証されました"
}
