#!/bin/bash
# 通知ライブラリ
set -euo pipefail

# Discord Webhook通知関数
send_discord_notification() {
    local title="$1"
    local message="$2"
    local level="${3:-info}"  # info, warning, error
    local webhook_url="${DISCORD_WEBHOOK_URL:-}"
    
    if [ -z "$webhook_url" ]; then
        log_warning "Discord Webhook URLが設定されていません"
        return 1
    fi
    
    # カラー設定
    local color
    case $level in
        "error")   color="15158332" ;;  # 赤
        "warning") color="16776960" ;;  # 黄
        "success") color="65280" ;;     # 緑
        *)         color="3447003" ;;   # 青（info）
    esac
    
    # JSON payload作成
    local payload=$(cat << EOF
{
    "embeds": [{
        "title": "$title",
        "description": "$message",
        "color": $color,
        "timestamp": "$(date -Iseconds)",
        "footer": {
            "text": "MediaServer $(hostname)"
        },
        "fields": [
            {
                "name": "サーバー",
                "value": "$(hostname)",
                "inline": true
            },
            {
                "name": "IP",
                "value": "$(hostname -I | awk '{print $1}')",
                "inline": true
            }
        ]
    }]
}
EOF
    )
    
    # Discord Webhook送信
    if curl -H "Content-Type: application/json" \
            -d "$payload" \
            -s "$webhook_url" > /dev/null; then
        log_info "Discord通知送信完了"
        return 0
    else
        log_error "Discord通知送信失敗"
        return 1
    fi
}

# LINE Notify機能は削除されました（Discord Webhook使用）

# Pushover通知関数
send_pushover_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}"  # -2,-1,0,1,2
    local token="${PUSHOVER_APP_TOKEN:-}"
    local user="${PUSHOVER_USER_KEY:-}"
    
    if [ -z "$token" ] || [ -z "$user" ]; then
        log_warning "Pushover トークンまたはユーザーキーが設定されていません"
        return 1
    fi
    
    # Pushover送信
    if curl -s \
            --form-string "token=$token" \
            --form-string "user=$user" \
            --form-string "title=$title" \
            --form-string "message=$message" \
            --form-string "priority=$priority" \
            https://api.pushover.net/1/messages.json > /dev/null; then
        log_info "Pushover通知送信完了"
        return 0
    else
        log_error "Pushover通知送信失敗"
        return 1
    fi
}

# ヘルスチェック結果通知
send_health_notification() {
    local health_status="$1"
    local report="$2"
    local critical_count="${3:-0}"
    local warning_count="${4:-0}"
    local is_report_mode="${5:-false}"
    
    local title
    local level
    
    if [ "$is_report_mode" = "true" ]; then
        title="📊 日次ヘルスレポート"
        level="info"
        case $health_status in
            0) title="📊 日次レポート（正常）" ;;
            1) title="📊 日次レポート（警告あり）" ;;
            2) title="📊 日次レポート（重大エラーあり）" ;;
        esac
    else
        case $health_status in
            0)
                title="✅ システム正常"
                level="success"
                ;;
            1)
                title="⚠️ システム警告"
                level="warning"
                ;;
            2)
                title="🔥 システム重大エラー"
                level="error"
                ;;
            *)
                title="❓ システム状態不明"
                level="info"
                ;;
        esac
    fi
    
    local message="重大: ${critical_count}件, 警告: ${warning_count}件\n\n$report"
    
    # Discord通知送信
    if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        send_discord_notification "$title" "$message" "$level"
    else
        log_warning "Discord Webhook URLが設定されていません"
        return 1
    fi
}

# バックアップ結果通知
send_backup_notification() {
    local status="$1"      # success/error
    local backup_type="$2" # deploy/daily/weekly/monthly
    local details="$3"
    
    local title
    local level
    
    if [ "$status" = "success" ]; then
        title="✅ バックアップ完了"
        level="success"
    else
        title="❌ バックアップ失敗"
        level="error"
    fi
    
    local message="種別: ${backup_type}\n${details}"
    
    # Discord通知送信
    if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        send_discord_notification "$title" "$message" "$level"
    else
        log_warning "Discord Webhook URLが設定されていません"
        return 1
    fi
}

# システム更新通知
send_update_notification() {
    local status="$1"      # success/error
    local update_type="$2" # system/docker/full
    local details="$3"
    
    local title
    local level
    
    if [ "$status" = "success" ]; then
        title="🔄 システム更新完了"
        level="success"
    else
        title="⚠️ システム更新失敗"
        level="error"
    fi
    
    local message="更新種別: ${update_type}\n${details}"
    
    # Discord通知送信
    if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        send_discord_notification "$title" "$message" "$level"
    else
        log_warning "Discord Webhook URLが設定されていません"
        return 1
    fi
}

# セキュリティアラート通知
send_security_alert() {
    local alert_type="$1"  # ssh_attack/firewall_block/etc
    local details="$2"
    
    local title="🚨 セキュリティアラート: $alert_type"
    local level="error"
    
    # Discord通知送信（緊急度高）
    if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        send_discord_notification "$title" "$details" "$level"
    else
        log_error "Discord Webhook URLが設定されていません（セキュリティアラート）"
        return 1
    fi
}

# 通知テスト関数
test_notifications() {
    log_info "=== Discord通知テスト開始 ==="
    
    local test_title="📱 通知テスト"
    local test_message="MediaServerからのテスト通知です。\n時刻: $(date)\nサーバー: $(hostname)"
    
    if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        log_info "Discord通知テスト中..."
        if send_discord_notification "$test_title" "$test_message" "info"; then
            log_success "Discord通知テスト完了"
        else
            log_error "Discord通知テスト失敗"
            return 1
        fi
    else
        log_error "Discord Webhook URLが設定されていません"
        return 1
    fi
}
