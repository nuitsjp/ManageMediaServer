#!/bin/bash
# サービス管理ライブラリ（rclone、systemd、外部統合管理）

# rcloneインストール
install_rclone() {
    log_info "=== rcloneのインストール ==="
    
    # rcloneの公式GPGキーを追加
    curl https://rclone.org/install.sh | sudo bash
    
    log_success "rcloneのインストールが完了しました"
}

# systemdサービス設定（本番環境用）
setup_systemd_services() {
    log_info "=== systemdサービス設定 ==="
    
    create_rclone_sync_service
    create_docker_compose_service
    setup_systemd_timers
    
    # 本番環境: サービスをブート時に自動起動
    systemctl daemon-reload
    systemctl enable immich.service jellyfin.service rclone-sync.timer
    
    log_success "systemdサービス設定完了"
}

# rclone同期サービス作成
create_rclone_sync_service() {
    log_info "rclone同期サービスを作成中..."
    
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

# Docker Compose systemdサービス作成
create_docker_compose_service() {
    log_info "Docker Compose systemdサービスを作成中..."
    
    local env_type=$(detect_environment)
    
    # 統一パス構成に対応
    # Immich
    cat << EOF | tee "$SYSTEMD_CONFIG_PATH/immich.service"
[Unit]
Description=Immich Media Server
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=mediaserver
WorkingDirectory=$PROJECT_ROOT
ExecStart=/usr/bin/docker compose -f $PROJECT_ROOT/docker/immich/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f $PROJECT_ROOT/docker/immich/docker-compose.yml down
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Jellyfin
    cat << EOF | tee "$SYSTEMD_CONFIG_PATH/jellyfin.service"
[Unit]
Description=Jellyfin Media Server
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=mediaserver
WorkingDirectory=$PROJECT_ROOT
ExecStart=/usr/bin/docker compose -f $PROJECT_ROOT/docker/jellyfin/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f $PROJECT_ROOT/docker/jellyfin/docker-compose.yml down
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    log_success "Docker Compose systemdサービスを作成しました"
}

# systemdタイマー設定
setup_systemd_timers() {
    log_info "systemdタイマーを設定中..."
    
    cat << EOF | sudo tee "$SYSTEMD_CONFIG_PATH/rclone-sync.timer"
[Unit]
Description=Run rclone sync hourly
Requires=rclone-sync.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable rclone-sync.timer
    
    log_success "systemdタイマー設定完了"
}

# サービス状態チェック
check_service_status() {
    local service_name=$1
    
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_success "サービス確認: $service_name (正常動作)"
        return 0
    else
        log_warning "サービス確認: $service_name (動作異常)"
        return 1
    fi
}

# 複数サービス状態チェック
check_multiple_services() {
    local services=("$@")
    local failed_services=()
    
    log_info "サービス状態確認中..."
    
    for service in "${services[@]}"; do
        if ! check_service_status "$service"; then
            failed_services+=("$service")
        fi
    done
    
    if [ ${#failed_services[@]} -gt 0 ]; then
        log_warning "以下のサービスで問題が検出されました: ${failed_services[*]}"
        return 1
    else
        log_success "全サービスが正常に動作しています"
        return 0
    fi
}

# サービス起動・停止管理
manage_service() {
    local action=$1
    local service_name=$2
    
    case $action in
        "start")
            log_info "$service_name サービスを開始中..."
            systemctl start "$service_name"
            ;;
        "stop")
            log_info "$service_name サービスを停止中..."
            systemctl stop "$service_name"
            ;;
        "restart")
            log_info "$service_name サービスを再起動中..."
            systemctl restart "$service_name"
            ;;
        "enable")
            log_info "$service_name サービスの自動起動を有効化中..."
            systemctl enable "$service_name"
            ;;
        "disable")
            log_info "$service_name サービスの自動起動を無効化中..."
            systemctl disable "$service_name"
            ;;
        *)
            log_error "不正な操作: $action"
            ;;
    esac
    
    log_success "$service_name サービスの$action操作が完了しました"
}

# アプリケーションヘルスチェック
check_application_health() {
    local app_name=$1
    local url=$2
    local timeout=${3:-10}
    
    if curl -f -s --max-time "$timeout" "$url" >/dev/null 2>&1; then
        log_success "$app_name ヘルスチェック: 正常"
        return 0
    else
        log_warning "$app_name ヘルスチェック: 異常"
        return 1
    fi
}

# 外部統合設定（将来拡張用）
setup_external_integrations() {
    log_info "=== 外部統合設定 ==="
    
    # 将来的にCloudflare、監視ツール等の統合設定を追加予定
    log_info "現在、外部統合は設定されていません"
    
    log_success "外部統合設定完了"
}

# rclone設定検証
validate_rclone_setup() {
    if ! command_exists rclone; then
        log_error "rcloneがインストールされていません"
        return 1
    fi
    
    if [ ! -f "$RCLONE_CONFIG_PATH/rclone.conf" ]; then
        log_warning "rclone設定ファイルが見つかりません: $RCLONE_CONFIG_PATH/rclone.conf"
        return 1
    fi
    
    log_success "rclone設定が正常に検証されました"
    return 0
}

# systemdサービス設定検証
validate_systemd_services() {
    local services=("immich.service" "jellyfin.service" "rclone-sync.service" "rclone-sync.timer")
    local missing_services=()
    
    for service in "${services[@]}"; do
        if [ ! -f "$SYSTEMD_CONFIG_PATH/$service" ]; then
            missing_services+=("$service")
        fi
    done
    
    if [ ${#missing_services[@]} -gt 0 ]; then
        log_warning "以下のsystemdサービス設定が見つかりません: ${missing_services[*]}"
        return 1
    fi
    
    log_success "systemdサービス設定が正常に検証されました"
    return 0
}

# 全サービス検証
validate_all_services() {
    log_info "=== サービス設定検証 ==="
    
    local validation_failed=false
    
    if ! validate_rclone_setup; then
        validation_failed=true
    fi
    
    if ! validate_systemd_services; then
        validation_failed=true
    fi
    
    if [ "$validation_failed" = "true" ]; then
        log_error "サービス設定の検証で問題が見つかりました"
        return 1
    fi
    
    log_success "全サービス設定の検証が完了しました"
    return 0
}
