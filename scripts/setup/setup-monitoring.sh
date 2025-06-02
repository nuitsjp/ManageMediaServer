#!/bin/bash
# 監視・通知の自動化設定スクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/notification.sh" || log_error "notification.sh の読み込みに失敗"

# 環境変数読み込み
load_environment

# 使用方法表示
show_usage() {
    cat << EOF
使用方法: $0 [オプション]

ヘルスチェックと通知の定期実行を設定します。

オプション:
    --setup          監視スケジュールを設定
    --enable         監視を有効化
    --disable        監視を無効化
    --status         現在の監視状態を表示
    --test           通知テストを実行
    --help           このヘルプを表示

設定される監視スケジュール:
    - 5分毎: 基本ヘルスチェック（エラー時のみ通知）
    - 1時間毎: 詳細ヘルスチェック（警告以上通知）
    - 1日毎: 総合レポート通知

例:
    ./setup-monitoring.sh --setup      # 監視設定
    ./setup-monitoring.sh --status     # 状態確認
    ./setup-monitoring.sh --test       # 通知テスト

EOF
}

# systemdタイマー作成
create_health_check_timers() {
    log_info "=== ヘルスチェックタイマー作成 ==="
    
    # 基本ヘルスチェック（5分毎、エラー時のみ通知）
    log_info "基本ヘルスチェックサービス作成中..."
    cat << EOF | sudo tee "$SYSTEMD_CONFIG_PATH/health-check-basic.service"
[Unit]
Description=Basic Health Check (Error notifications only)
After=network.target

[Service]
Type=oneshot
User=mediaserver
Environment=PROJECT_ROOT=$PROJECT_ROOT
WorkingDirectory=$PROJECT_ROOT
ExecStart=$PROJECT_ROOT/scripts/monitoring/health-check.sh --notify --threshold error
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    
    cat << EOF | sudo tee "$SYSTEMD_CONFIG_PATH/health-check-basic.timer"
[Unit]
Description=Run basic health check every 5 minutes
Requires=health-check-basic.service

[Timer]
OnCalendar=*:*/5
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # 詳細ヘルスチェック（1時間毎、警告以上通知）
    log_info "詳細ヘルスチェックサービス作成中..."
    cat << EOF | sudo tee "$SYSTEMD_CONFIG_PATH/health-check-detailed.service"
[Unit]
Description=Detailed Health Check (Warning+ notifications)
After=network.target

[Service]
Type=oneshot
User=mediaserver
Environment=PROJECT_ROOT=$PROJECT_ROOT
WorkingDirectory=$PROJECT_ROOT
ExecStart=$PROJECT_ROOT/scripts/monitoring/health-check.sh --notify --threshold warning --detailed
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    
    cat << EOF | sudo tee "$SYSTEMD_CONFIG_PATH/health-check-detailed.timer"
[Unit]
Description=Run detailed health check hourly
Requires=health-check-detailed.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # 日次レポート（毎日AM8:00、情報レベル以上通知）
    log_info "日次レポートサービス作成中..."
    cat << EOF | sudo tee "$SYSTEMD_CONFIG_PATH/health-check-daily.service"
[Unit]
Description=Daily Health Check Report
After=network.target

[Service]
Type=oneshot
User=mediaserver
Environment=PROJECT_ROOT=$PROJECT_ROOT
WorkingDirectory=$PROJECT_ROOT
ExecStart=$PROJECT_ROOT/scripts/monitoring/health-check.sh --notify --threshold info --detailed --report
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    
    cat << EOF | sudo tee "$SYSTEMD_CONFIG_PATH/health-check-daily.timer"
[Unit]
Description=Run daily health check report at 8:00 AM
Requires=health-check-daily.service

[Timer]
OnCalendar=08:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    log_success "ヘルスチェックタイマー作成完了"
}

# 監視設定
setup_monitoring() {
    log_info "=== 監視システム設定 ==="
    
    # 前提条件確認
    if [ ! -f "$PROJECT_ROOT/config/env/notification.env" ]; then
        log_error "通知設定が見つかりません。先に通知設定を行ってください:"
        log_info "  $PROJECT_ROOT/scripts/setup/setup-notification.sh --setup"
        return 1
    fi
    
    # 通知設定確認
    source "$PROJECT_ROOT/config/env/notification.env"
    if [ "$NOTIFICATION_ENABLED" != "true" ] || [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
        log_error "通知機能が正しく設定されていません"
        log_info "通知設定を確認してください:"
        log_info "  $PROJECT_ROOT/scripts/setup/setup-notification.sh --status"
        return 1
    fi
    
    # systemd権限確認
    if [ "$EUID" -ne 0 ]; then
        log_error "systemdタイマー作成には管理者権限が必要です"
        log_info "sudo で実行してください: sudo $0 --setup"
        return 1
    fi
    
    # タイマー作成
    create_health_check_timers
    
    # systemd設定リロード
    log_info "systemd設定をリロード中..."
    systemctl daemon-reload
    
    log_success "監視システム設定完了"
    log_info "有効化するには: $0 --enable"
}

# 監視有効化
enable_monitoring() {
    log_info "=== 監視システム有効化 ==="
    
    if [ "$EUID" -ne 0 ]; then
        log_error "監視システム有効化には管理者権限が必要です"
        log_info "sudo で実行してください: sudo $0 --enable"
        return 1
    fi
    
    local timers=(
        "health-check-basic.timer"
        "health-check-detailed.timer"
        "health-check-daily.timer"
    )
    
    for timer in "${timers[@]}"; do
        if [ -f "$SYSTEMD_CONFIG_PATH/$timer" ]; then
            log_info "$timer を有効化中..."
            systemctl enable "$timer"
            systemctl start "$timer"
            log_success "$timer 有効化完了"
        else
            log_warning "$timer が見つかりません。先に設定を行ってください"
        fi
    done
    
    log_success "監視システム有効化完了"
    
    # 有効化完了通知
    send_notification "📊 監視システム有効化" "ヘルスチェック監視が有効化されました\n\n• 基本チェック: 5分毎（エラー時通知）\n• 詳細チェック: 1時間毎（警告以上通知）\n• 日次レポート: 毎日8:00（全体レポート）" "success"
}

# 監視無効化
disable_monitoring() {
    log_info "=== 監視システム無効化 ==="
    
    if [ "$EUID" -ne 0 ]; then
        log_error "監視システム無効化には管理者権限が必要です"
        log_info "sudo で実行してください: sudo $0 --disable"
        return 1
    fi
    
    local timers=(
        "health-check-basic.timer"
        "health-check-detailed.timer" 
        "health-check-daily.timer"
    )
    
    for timer in "${timers[@]}"; do
        if systemctl is-active --quiet "$timer" 2>/dev/null; then
            log_info "$timer を無効化中..."
            systemctl stop "$timer"
            systemctl disable "$timer"
            log_success "$timer 無効化完了"
        else
            log_info "$timer は既に無効化されています"
        fi
    done
    
    log_success "監視システム無効化完了"
    
    # 無効化完了通知
    send_notification "📊 監視システム無効化" "ヘルスチェック監視が無効化されました\n\n手動でのヘルスチェックは引き続き利用可能です" "warning"
}

# 監視状態表示
show_monitoring_status() {
    log_info "=== 監視システム状態 ==="
    
    local timers=(
        "health-check-basic.timer"
        "health-check-detailed.timer"
        "health-check-daily.timer"
    )
    
    for timer in "${timers[@]}"; do
        if systemctl is-active --quiet "$timer" 2>/dev/null; then
            log_success "$timer: 有効"
            # 次回実行時刻表示
            local next_run=$(systemctl list-timers --no-pager | grep "$timer" | awk '{print $1, $2, $3}' 2>/dev/null || echo "不明")
            log_info "  次回実行: $next_run"
        else
            log_warning "$timer: 無効"
        fi
    done
    
    echo ""
    log_info "最近のヘルスチェックログ（最新5件）:"
    journalctl -u health-check-*.service -n 5 --no-pager --since "24 hours ago" 2>/dev/null || log_info "ログが見つかりません"
}

# 通知テスト
test_monitoring() {
    log_info "=== 監視通知テスト ==="
    
    # 通知設定確認
    if [ ! -f "$PROJECT_ROOT/config/env/notification.env" ]; then
        log_error "通知設定が見つかりません"
        return 1
    fi
    
    source "$PROJECT_ROOT/config/env/notification.env"
    
    # テスト通知送信
    send_notification "🧪 監視テスト" "監視システムのテスト通知です\n\n• 基本ヘルスチェック: 5分毎\n• 詳細ヘルスチェック: 1時間毎\n• 日次レポート: 毎日8:00\n• 送信時刻: $(date '+%Y-%m-%d %H:%M:%S')" "info"
    
    if [ $? -eq 0 ]; then
        log_success "テスト通知送信完了"
    else
        log_error "テスト通知送信失敗"
    fi
}

# メイン処理
main() {
    local setup=false
    local enable=false
    local disable=false
    local status=false
    local test=false
    
    # 引数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            --setup)
                setup=true
                ;;
            --enable)
                enable=true
                ;;
            --disable)
                disable=true
                ;;
            --status)
                status=true
                ;;
            --test)
                test=true
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                log_error "不明なオプション: $1"
                show_usage
                exit 1
                ;;
        esac
        shift
    done
    
    # オプションに応じて実行
    if [ "$setup" = "true" ]; then
        setup_monitoring
    elif [ "$enable" = "true" ]; then
        enable_monitoring
    elif [ "$disable" = "true" ]; then
        disable_monitoring
    elif [ "$status" = "true" ]; then
        show_monitoring_status
    elif [ "$test" = "true" ]; then
        test_monitoring
    else
        show_usage
    fi
}

# スクリプト実行
main "$@"
