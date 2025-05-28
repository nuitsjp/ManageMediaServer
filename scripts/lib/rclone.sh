#!/bin/bash
# rclone専用ライブラリ（rcloneアプリケーション特化機能）

# rclone全体セットアップ
setup_rclone() {
    log_info "=== rclone セットアップ開始 ==="
    
    install_rclone
    create_rclone_directories
    
    # rclone設定検証（設定ファイルが存在しない場合は警告のみ）
    if ! validate_rclone_setup; then
        log_warning "rclone設定ファイルが見つかりません。手動で設定してください。"
        log_info "設定コマンド: rclone config"
        log_info "rcloneセットアップは継続します..."
    fi
    
    log_success "=== rclone セットアップ完了 ==="
}

# rcloneインストール
install_rclone() {
    log_info "=== rcloneのインストール ==="
    
    # rcloneが既にインストール済みかチェック
    if command -v rclone >/dev/null 2>&1; then
        local current_version=$(rclone version | head -n1 | awk '{print $2}')
        log_info "rclone は既にインストール済みです (バージョン: $current_version)"
        log_success "rcloneのインストールが完了しました"
        return 0
    fi
    
    # rcloneの公式インストールスクリプトを実行
    log_info "rcloneをインストール中..."
    curl -fsSL https://rclone.org/install.sh | bash
    
    # インストール確認
    if command -v rclone >/dev/null 2>&1; then
        local installed_version=$(rclone version | head -n1 | awk '{print $2}')
        log_success "rcloneのインストールが完了しました (バージョン: $installed_version)"
    else
        log_error "rcloneのインストールに失敗しました"
        return 1
    fi
}

# rcloneディレクトリ作成
create_rclone_directories() {
    local rclone_dirs=(
        "$DATA_ROOT/config/rclone"
        "$DATA_ROOT/config/rclone/logs"
        "$DATA_ROOT/immich/external"
    )
    
    for dir in "${rclone_dirs[@]}"; do
        ensure_dir_exists "$dir"
    done
    
    log_debug "rclone用ディレクトリ構造を準備しました"
}

# rclone同期サービス作成
create_rclone_sync_service() {
    log_info "rclone同期サービスを作成中..."
    
    # rclone設定ファイルのディレクトリパスを取得
    local rclone_config_dir=$(dirname "$RCLONE_CONFIG_PATH")
    
    cat << EOF | tee "$SYSTEMD_CONFIG_PATH/rclone-sync.service"
[Unit]
Description=rclone sync media files
After=network.target

[Service]
Type=oneshot
User=mediaserver
Environment=RCLONE_CONFIG=$RCLONE_CONFIG_PATH
ExecStart=/usr/bin/rclone sync ${RCLONE_REMOTE_NAME}:/ $DATA_ROOT/immich/external --log-file=$RCLONE_LOG_PATH/sync.log --log-level INFO
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    log_success "rclone同期サービスを作成しました"
}

# systemdタイマー設定
setup_rclone_timer() {
    log_info "rcloneタイマーを設定中..."
    
    cat << EOF | tee "$SYSTEMD_CONFIG_PATH/rclone-sync.timer"
[Unit]
Description=Run rclone sync hourly
Requires=rclone-sync.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    log_success "rcloneタイマー設定完了"
}

# rclone設定検証
validate_rclone_setup() {
    if ! command_exists rclone; then
        log_error "rcloneがインストールされていません"
        return 1
    fi
    
    if [ ! -f "$RCLONE_CONFIG_PATH" ]; then
        log_warning "rclone設定ファイルが見つかりません: $RCLONE_CONFIG_PATH"
        log_info "rclone設定を行ってください: rclone config"
        return 1
    fi
    
    log_success "rclone設定が正常に検証されました"
    return 0
}

# rclone設定ファイル準備
configure_rclone_environment() {
    local config_file="$RCLONE_CONFIG_PATH"
    local example_file="$PROJECT_ROOT/config/rclone/rclone.conf.example"
    
    # 設定ファイルが存在しない場合、exampleからコピー
    if [ ! -f "$config_file" ] && [ -f "$example_file" ]; then
        log_info "rclone設定ファイルをexampleからコピー中..."
        cp "$example_file" "$config_file"
        log_warning "rclone設定ファイルをコピーしました。実際の認証情報を設定してください。"
        log_info "設定コマンド: rclone config"
    fi
}

# rclone手動同期実行
run_rclone_sync() {
    local remote_name="${1:-${RCLONE_REMOTE_NAME}}"
    local local_path="${2:-$DATA_ROOT/immich/external}"
    
    log_info "rclone手動同期を実行中..."
    log_info "リモート: $remote_name:/ → ローカル: $local_path"
    
    if ! validate_rclone_setup; then
        log_error "rclone設定に問題があります。同期を中止します。"
        return 1
    fi
    
    # ドライランでテスト
    log_info "同期内容を確認中（ドライラン）..."
    if rclone sync "$remote_name:/" "$local_path" --dry-run --log-level INFO; then
        log_info "実際の同期を実行中..."
        rclone sync "$remote_name:/" "$local_path" --log-file="$RCLONE_LOG_PATH/manual-sync.log" --log-level INFO
        log_success "手動同期が完了しました"
    else
        log_error "同期のドライランでエラーが発生しました"
        return 1
    fi
}

# rcloneサービス状態確認
check_rclone_service_status() {
    log_info "rcloneサービス状態を確認中..."
    
    # サービス状態確認
    if systemctl is-active --quiet rclone-sync.service; then
        log_success "rclone-sync.service: 動作中"
    else
        log_info "rclone-sync.service: 停止中"
    fi
    
    # タイマー状態確認
    if systemctl is-active --quiet rclone-sync.timer; then
        log_success "rclone-sync.timer: 動作中"
        
        # 次回実行時刻を表示
        local next_run=$(systemctl list-timers --no-pager | grep rclone-sync.timer | awk '{print $1, $2, $3}')
        if [ -n "$next_run" ]; then
            log_info "次回実行予定: $next_run"
        fi
    else
        log_warning "rclone-sync.timer: 停止中"
    fi
    
    # 最近のログを表示
    log_info "最近の実行ログ（最新5件）:"
    journalctl -u rclone-sync.service -n 5 --no-pager --since "24 hours ago" || true
}

# rcloneリモート設定確認
list_rclone_remotes() {
    log_info "設定済みrcloneリモート一覧:"
    
    if command_exists rclone; then
        rclone listremotes
    else
        log_error "rcloneがインストールされていません"
        return 1
    fi
}

# rclone設定対話的セットアップ
setup_rclone_config() {
    log_info "rclone対話的設定を開始します..."
    log_info "Google Drive、OneDrive、Dropbox等のクラウドストレージを設定できます"
    
    if command_exists rclone; then
        rclone config
        log_success "rclone設定が完了しました"
        
        # 設定後の確認
        log_info "設定されたリモート:"
        rclone listremotes
    else
        log_error "rcloneがインストールされていません。先にinstall_rcloneを実行してください。"
        return 1
    fi
}
