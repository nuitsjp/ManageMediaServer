#!/bin/bash
# 通知設定スクリプト
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

Discord Webhook通知機能の設定と管理を行います。

オプション:
    --setup          対話式でDiscord Webhook設定を行う
    --test           Discord通知をテスト
    --url URL        Discord Webhook URLを直接設定
    --disable        通知機能を無効化
    --enable         通知機能を有効化
    --status         現在の通知設定を表示
    --help           このヘルプを表示

例:
    ./setup-notification.sh --setup     # 対話式設定
    ./setup-notification.sh --test      # 通知テスト
    ./setup-notification.sh --status    # 設定確認

EOF
}

# Discord Webhook設定
setup_discord() {
    log_info "=== Discord Webhook設定 ==="
    
    echo "Discord Webhookの設定方法："
    echo "1. Discordサーバーで設定 → インテグレーション → ウェブフック"
    echo "2. 新しいウェブフックを作成"
    echo "3. ウェブフックURLをコピー"
    echo ""
    
    read -p "Discord Webhook URL: " webhook_url
    
    setup_discord_url "$webhook_url"
}

# Discord Webhook URL設定
setup_discord_url() {
    local webhook_url="$1"
    
    if [ -n "$webhook_url" ]; then
        # 設定ファイル更新
        sed -i "s|DISCORD_WEBHOOK_URL=.*|DISCORD_WEBHOOK_URL=\"$webhook_url\"|" "$PROJECT_ROOT/config/env/notification.env"
        log_success "Discord Webhook URLを設定しました"
        
        # テスト送信
        if confirm_action "テスト通知を送信しますか？"; then
            DISCORD_WEBHOOK_URL="$webhook_url"
            if send_discord_notification "📱 設定テスト" "Discord Webhookの設定が完了しました。" "success"; then
                log_success "Discord通知テスト成功"
            else
                log_error "Discord通知テスト失敗"
            fi
        fi
    else
        log_warning "Discord Webhook URLが入力されませんでした"
    fi
}

# 対話式設定
interactive_setup() {
    log_info "=== Discord Webhook通知設定 ==="
    
    echo "Discord Webhookを設定します："
    echo "Discord Webhookは無料で使用でき、履歴も残るため推奨です。"
    echo ""
    
    setup_discord
    
    # 通知機能有効化
    sed -i "s|NOTIFICATION_ENABLED=.*|NOTIFICATION_ENABLED=true|" "$PROJECT_ROOT/config/env/notification.env"
    log_success "通知機能を有効化しました"
}

# 設定状態表示
show_status() {
    log_info "=== Discord通知設定状態 ==="
    
    # 設定ファイル読み込み
    if [ -f "$PROJECT_ROOT/config/env/notification.env" ]; then
        source "$PROJECT_ROOT/config/env/notification.env"
        
        echo "通知機能: $([ "$NOTIFICATION_ENABLED" = "true" ] && echo "有効" || echo "無効")"
        echo "通知レベル: $NOTIFICATION_LEVEL"
        echo ""
        
        echo "Discord Webhook設定:"
        if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
            echo "- URL: 設定済み ($(echo "$DISCORD_WEBHOOK_URL" | cut -c1-50)...)"
        else
            echo "- URL: 未設定"
        fi
    else
        log_warning "通知設定ファイルが見つかりません"
    fi
}

# 通知有効化
enable_notifications() {
    sed -i "s|NOTIFICATION_ENABLED=.*|NOTIFICATION_ENABLED=true|" "$PROJECT_ROOT/config/env/notification.env"
    log_success "通知機能を有効化しました"
}

# 通知無効化
disable_notifications() {
    sed -i "s|NOTIFICATION_ENABLED=.*|NOTIFICATION_ENABLED=false|" "$PROJECT_ROOT/config/env/notification.env"
    log_success "通知機能を無効化しました"
}

# メイン処理
main() {
    local setup=false
    local test=false
    local enable=false
    local disable=false
    local status=false
    local webhook_url=""
    
    # 引数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            --setup)
                setup=true
                ;;
            --test)
                test=true
                ;;
            --url)
                webhook_url="$2"
                shift
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
    
    # 設定ファイルディレクトリ作成
    ensure_dir_exists "$PROJECT_ROOT/config/env"
    
    # 通知設定ファイル作成（存在しない場合）
    if [ ! -f "$PROJECT_ROOT/config/env/notification.env" ]; then
        log_info "通知設定ファイルを作成しています..."
        cat > "$PROJECT_ROOT/config/env/notification.env" << 'EOF'
# Discord Webhook通知設定
DISCORD_WEBHOOK_URL=""

# 通知設定
NOTIFICATION_ENABLED=false
NOTIFICATION_LEVEL="warning"
HEALTH_CHECK_NOTIFY_THRESHOLD="warning"
EOF
    fi
    
    # オプションに応じて実行
    if [ "$setup" = "true" ]; then
        interactive_setup
    elif [ "$test" = "true" ]; then
        source "$PROJECT_ROOT/config/env/notification.env"
        test_notifications
    elif [ -n "$webhook_url" ]; then
        setup_discord_url "$webhook_url"
    elif [ "$enable" = "true" ]; then
        enable_notifications
    elif [ "$disable" = "true" ]; then
        disable_notifications
    elif [ "$status" = "true" ]; then
        show_status
    else
        show_usage
    fi
}

# スクリプト実行
main "$@"
