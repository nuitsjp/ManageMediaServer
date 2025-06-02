#!/bin/bash
# ヘルスチェックスクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/notification.sh" || log_warning "notification.sh の読み込みに失敗（通知機能無効）"

# 環境変数読み込み
load_environment

# ヘルスチェック結果格納
HEALTH_STATUS=0
HEALTH_REPORT=""
CRITICAL_ISSUES=()
WARNING_ISSUES=()

# 使用方法表示
show_usage() {
    cat << EOF
使用方法: $0 [オプション]

システム全体のヘルスチェックを実行し、問題がある場合は報告します。

オプション:
    --json           JSON形式で結果を出力
    --silent         警告メッセージを抑制（エラーのみ表示）
    --nagios         Nagios互換の出力形式
    --fix-issues     自動修復可能な問題を修復
    --detailed       詳細情報を表示
    --notify         結果を通知サービスに送信
    --threshold LEV  通知閾値（error/warning/info）
    --report         レポート形式での詳細出力
    --help           このヘルプを表示

チェック項目:
    - システムリソース（CPU、メモリ、ディスク）
    - Dockerサービス状態
    - アプリケーション応答
    - ネットワーク接続
    - ログエラー確認
    - バックアップ状態

例:
    ./health-check.sh                          # 標準ヘルスチェック
    ./health-check.sh --json                   # JSON出力
    ./health-check.sh --notify --threshold warning  # 警告以上で通知
    ./health-check.sh --detailed --report      # 詳細レポート

EOF
}

# ヘルスチェック結果追加
add_health_result() {
    local status=$1
    local component=$2
    local message=$3
    local details=${4:-""}
    
    case $status in
        "OK")
            HEALTH_REPORT+="[OK] $component: $message\n"
            ;;
        "WARNING")
            HEALTH_REPORT+="[WARNING] $component: $message\n"
            WARNING_ISSUES+=("$component: $message")
            if [ $HEALTH_STATUS -lt 1 ]; then
                HEALTH_STATUS=1
            fi
            ;;
        "CRITICAL")
            HEALTH_REPORT+="[CRITICAL] $component: $message\n"
            CRITICAL_ISSUES+=("$component: $message")
            HEALTH_STATUS=2
            ;;
    esac
    
    if [ -n "$details" ]; then
        HEALTH_REPORT+="  詳細: $details\n"
    fi
}

# システムリソースチェック
check_system_resources() {
    log_info "システムリソースをチェック中..."
    
    # CPU使用率チェック
    local cpu_usage=$(top -bn1 | grep "load average:" | awk '{print $10}' | sed 's/,//')
    local cpu_cores=$(nproc)
    local cpu_load=$(echo "$cpu_usage / $cpu_cores" | bc -l)
    
    if (( $(echo "$cpu_load > 0.8" | bc -l) )); then
        add_health_result "WARNING" "CPU" "高負荷状態 (${cpu_usage}/${cpu_cores})"
    elif (( $(echo "$cpu_load > 0.9" | bc -l) )); then
        add_health_result "CRITICAL" "CPU" "非常に高い負荷 (${cpu_usage}/${cpu_cores})"
    else
        add_health_result "OK" "CPU" "負荷正常 (${cpu_usage}/${cpu_cores})"
    fi
    
    # メモリ使用率チェック
    local mem_info=$(free | awk 'NR==2{printf "%.1f", $3*100/$2 }')
    if (( $(echo "$mem_info > 85" | bc -l) )); then
        add_health_result "WARNING" "Memory" "メモリ使用率高 (${mem_info}%)"
    elif (( $(echo "$mem_info > 95" | bc -l) )); then
        add_health_result "CRITICAL" "Memory" "メモリ使用率危険 (${mem_info}%)"
    else
        add_health_result "OK" "Memory" "メモリ使用率正常 (${mem_info}%)"
    fi
    
    # ディスク使用率チェック
    local disk_usage_root=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$disk_usage_root" -gt 85 ]; then
        add_health_result "WARNING" "Disk" "ルートディスク使用率高 (${disk_usage_root}%)"
    elif [ "$disk_usage_root" -gt 95 ]; then
        add_health_result "CRITICAL" "Disk" "ルートディスク容量危険 (${disk_usage_root}%)"
    else
        add_health_result "OK" "Disk" "ルートディスク使用率正常 (${disk_usage_root}%)"
    fi
    
    # データディスク使用率チェック
    if mountpoint -q "$DATA_ROOT" 2>/dev/null; then
        local disk_usage_data=$(df "$DATA_ROOT" | awk 'NR==2 {print $5}' | sed 's/%//')
        if [ "$disk_usage_data" -gt 85 ]; then
            add_health_result "WARNING" "Disk" "データディスク使用率高 (${disk_usage_data}%)"
        elif [ "$disk_usage_data" -gt 95 ]; then
            add_health_result "CRITICAL" "Disk" "データディスク容量危険 (${disk_usage_data}%)"
        else
            add_health_result "OK" "Disk" "データディスク使用率正常 (${disk_usage_data}%)"
        fi
    fi
}

# Dockerサービスチェック
check_docker_services() {
    log_info "Dockerサービスをチェック中..."
    
    # Dockerデーモン確認
    if systemctl is-active --quiet docker; then
        add_health_result "OK" "Docker" "Dockerデーモン正常動作"
    else
        add_health_result "CRITICAL" "Docker" "Dockerデーモン停止"
        return
    fi
    
    # コンテナ状態確認
    local container_status=$(docker ps --format "{{.Names}}" 2>/dev/null || echo "")
    local expected_containers=("immich_server" "immich_postgres" "immich_redis" "jellyfin")
    
    for container in "${expected_containers[@]}"; do
        if echo "$container_status" | grep -q "$container"; then
            add_health_result "OK" "Docker" "$container コンテナ動作中"
        else
            add_health_result "WARNING" "Docker" "$container コンテナ停止"
        fi
    done
    
    # Docker リソース使用量
    local docker_disk=$(docker system df --format "table {{.Type}}\t{{.Size}}" | tail -n +2 | awk '{sum+=$2} END {print sum}')
    if [ -n "$docker_disk" ] && [ "$docker_disk" -gt 20 ]; then
        add_health_result "WARNING" "Docker" "Docker使用容量大 (${docker_disk}GB)"
    fi
}

# アプリケーション応答チェック
check_application_response() {
    log_info "アプリケーション応答をチェック中..."
    
    # Immich ヘルスチェック
    if curl -f -s --max-time 10 http://localhost:2283/api/server-info/ping >/dev/null; then
        add_health_result "OK" "Immich" "API応答正常"
    else
        add_health_result "CRITICAL" "Immich" "API応答なし"
    fi
    
    # Immich Web UI チェック
    if curl -f -s --max-time 10 http://localhost:2283 >/dev/null; then
        add_health_result "OK" "Immich" "Web UI応答正常"
    else
        add_health_result "WARNING" "Immich" "Web UI応答異常"
    fi
    
    # Jellyfin ヘルスチェック
    if curl -f -s --max-time 10 http://localhost:8096/health >/dev/null; then
        add_health_result "OK" "Jellyfin" "ヘルスチェック正常"
    else
        add_health_result "WARNING" "Jellyfin" "ヘルスチェック異常"
    fi
    
    # Jellyfin Web UI チェック
    if curl -f -s --max-time 10 http://localhost:8096 >/dev/null; then
        add_health_result "OK" "Jellyfin" "Web UI応答正常"
    else
        add_health_result "WARNING" "Jellyfin" "Web UI応答異常"
    fi
}

# ネットワーク接続チェック
check_network_connectivity() {
    log_info "ネットワーク接続をチェック中..."
    
    # インターネット接続確認
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        add_health_result "OK" "Network" "インターネット接続正常"
    else
        add_health_result "WARNING" "Network" "インターネット接続異常"
    fi
    
    # DNS解決確認
    if nslookup google.com >/dev/null 2>&1; then
        add_health_result "OK" "Network" "DNS解決正常"
    else
        add_health_result "WARNING" "Network" "DNS解決異常"
    fi
    
    # ローカルネットワーク確認
    local gateway=$(ip route | grep default | awk '{print $3}')
    if [ -n "$gateway" ] && ping -c 1 "$gateway" >/dev/null 2>&1; then
        add_health_result "OK" "Network" "ゲートウェイ接続正常"
    else
        add_health_result "WARNING" "Network" "ゲートウェイ接続異常"
    fi
}

# ログエラーチェック
check_log_errors() {
    log_info "ログエラーをチェック中..."
    
    # システムログエラー確認（過去1時間）
    local system_errors=$(journalctl --since "1 hour ago" --priority=err --no-pager -q | wc -l)
    if [ "$system_errors" -gt 10 ]; then
        add_health_result "WARNING" "Logs" "システムエラー多発 (${system_errors}件)"
    elif [ "$system_errors" -gt 50 ]; then
        add_health_result "CRITICAL" "Logs" "システムエラー大量発生 (${system_errors}件)"
    else
        add_health_result "OK" "Logs" "システムエラー正常範囲 (${system_errors}件)"
    fi
    
    # Docker ログエラー確認
    local docker_errors=0
    for container in $(docker ps --format "{{.Names}}" 2>/dev/null || echo ""); do
        local container_errors=$(docker logs --since 1h "$container" 2>&1 | grep -i "error\|exception\|fatal" | wc -l)
        docker_errors=$((docker_errors + container_errors))
    done
    
    if [ "$docker_errors" -gt 5 ]; then
        add_health_result "WARNING" "Logs" "Dockerエラー多発 (${docker_errors}件)"
    elif [ "$docker_errors" -gt 20 ]; then
        add_health_result "CRITICAL" "Logs" "Dockerエラー大量発生 (${docker_errors}件)"
    else
        add_health_result "OK" "Logs" "Dockerエラー正常範囲 (${docker_errors}件)"
    fi
}

# バックアップ状態チェック
check_backup_status() {
    log_info "バックアップ状態をチェック中..."
    
    # 最新バックアップ確認
    if [ -f "$BACKUP_ROOT/.last_backup_path" ]; then
        local last_backup=$(cat "$BACKUP_ROOT/.last_backup_path")
        if [ -d "$last_backup" ]; then
            local backup_age=$(find "$last_backup" -maxdepth 0 -mtime +7)
            if [ -n "$backup_age" ]; then
                add_health_result "WARNING" "Backup" "バックアップが古い (1週間以上)"
            else
                add_health_result "OK" "Backup" "バックアップ正常"
            fi
        else
            add_health_result "WARNING" "Backup" "バックアップディレクトリ不在"
        fi
    else
        add_health_result "WARNING" "Backup" "バックアップ履歴なし"
    fi
    
    # バックアップ領域容量確認
    if mountpoint -q "$BACKUP_ROOT" 2>/dev/null; then
        local backup_usage=$(df "$BACKUP_ROOT" | awk 'NR==2 {print $5}' | sed 's/%//')
        if [ "$backup_usage" -gt 90 ]; then
            add_health_result "WARNING" "Backup" "バックアップ領域容量不足 (${backup_usage}%)"
        else
            add_health_result "OK" "Backup" "バックアップ領域容量正常 (${backup_usage}%)"
        fi
    fi
}

# 自動修復実行
perform_auto_fix() {
    log_info "=== 自動修復を実行中 ==="
    
    # Docker未使用イメージ削除
    if docker images --filter "dangling=true" -q | grep -q .; then
        log_info "未使用Dockerイメージを削除中..."
        docker image prune -f
    fi
    
    # Docker未使用ボリューム削除
    if docker volume ls --filter "dangling=true" -q | grep -q .; then
        log_info "未使用Dockerボリュームを削除中..."
        docker volume prune -f
    fi
    
    # システムログローテーション
    if command_exists logrotate; then
        log_info "ログローテーションを実行中..."
        sudo logrotate -f /etc/logrotate.conf 2>/dev/null || true
    fi
    
    # 一時ファイル削除
    if [ -d "$DATA_ROOT/temp" ]; then
        log_info "一時ファイルを削除中..."
        find "$DATA_ROOT/temp" -type f -mtime +7 -delete 2>/dev/null || true
    fi
    
    log_success "自動修復完了"
}

# JSON出力
output_json() {
    cat << EOF
{
  "timestamp": "$(date -Iseconds)",
  "overall_status": $HEALTH_STATUS,
  "status_text": "$([ $HEALTH_STATUS -eq 0 ] && echo "OK" || [ $HEALTH_STATUS -eq 1 ] && echo "WARNING" || echo "CRITICAL")",
  "critical_issues": [$(printf '"%s",' "${CRITICAL_ISSUES[@]}" | sed 's/,$//')]",
  "warning_issues": [$(printf '"%s",' "${WARNING_ISSUES[@]}" | sed 's/,$//')]",
  "report": "$(echo -e "$HEALTH_REPORT" | sed 's/"/\\"/g' | tr '\n' '\\n')"
}
EOF
}

# Nagios出力
output_nagios() {
    local status_text
    case $HEALTH_STATUS in
        0) status_text="OK" ;;
        1) status_text="WARNING" ;;
        2) status_text="CRITICAL" ;;
        *) status_text="UNKNOWN" ;;
    esac
    
    echo "$status_text - Critical: ${#CRITICAL_ISSUES[@]}, Warning: ${#WARNING_ISSUES[@]}"
    exit $HEALTH_STATUS
}

# メイン処理
main() {
    # 初期化
    local json_output=false
    local silent=false
    local nagios_output=false
    local fix_issues=false
    local detailed=false
    local notify=false
    local notify_threshold="warning"
    local report_mode=false
    
    # 引数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json)
                json_output=true
                ;;
            --silent)
                silent=true
                ;;
            --nagios)
                nagios_output=true
                ;;
            --fix-issues)
                fix_issues=true
                ;;
            --detailed)
                detailed=true
                ;;
            --notify)
                notify=true
                ;;
            --threshold)
                notify_threshold="$2"
                shift
                ;;
            --report)
                report_mode=true
                detailed=true
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
    
    if [ "$silent" != "true" ]; then
        log_info "=== ヘルスチェック開始 ==="
    fi
    
    # 自動修復実行
    if [ "$fix_issues" = "true" ]; then
        perform_auto_fix
    fi
    
    # ヘルスチェック実行
    check_system_resources
    check_docker_services
    check_application_response
    check_network_connectivity
    check_log_errors
    check_backup_status
    
    # 結果出力
    if [ "$json_output" = "true" ]; then
        output_json
    elif [ "$nagios_output" = "true" ]; then
        output_nagios
    else
        if [ "$silent" != "true" ]; then
            log_info "=== ヘルスチェック結果 ==="
        fi
        
        echo -e "$HEALTH_REPORT"
        
        echo ""
        echo "=== サマリー ==="
        echo "全体状態: $([ $HEALTH_STATUS -eq 0 ] && echo "正常" || [ $HEALTH_STATUS -eq 1 ] && echo "警告" || echo "重大")"
        echo "重大な問題: ${#CRITICAL_ISSUES[@]}件"
        echo "警告: ${#WARNING_ISSUES[@]}件"
        
        if [ "$detailed" = "true" ] && [ ${#CRITICAL_ISSUES[@]} -gt 0 ]; then
            echo ""
            echo "=== 重大な問題詳細 ==="
            for issue in "${CRITICAL_ISSUES[@]}"; do
                echo "- $issue"
            done
        fi
        
        if [ "$detailed" = "true" ] && [ ${#WARNING_ISSUES[@]} -gt 0 ]; then
            echo ""
            echo "=== 警告詳細 ==="
            for issue in "${WARNING_ISSUES[@]}"; do
                echo "- $issue"
            done
        fi
    fi
    
    # 通知送信
    if [ "$notify" = "true" ] && command_exists send_health_notification; then
        local should_notify=false
        
        # 通知閾値判定
        case "$notify_threshold" in
            "error")
                [ $HEALTH_STATUS -ge 2 ] && should_notify=true
                ;;
            "warning")
                [ $HEALTH_STATUS -ge 1 ] && should_notify=true
                ;;
            "info")
                should_notify=true
                ;;
            *)
                log_warning "不明な通知閾値: $notify_threshold（warning を使用）"
                [ $HEALTH_STATUS -ge 1 ] && should_notify=true
                ;;
        esac
        
        if [ "$should_notify" = "true" ] || [ "$report_mode" = "true" ]; then
            local short_report=$(echo -e "$HEALTH_REPORT" | head -20)
            send_health_notification "$HEALTH_STATUS" "$short_report" "${#CRITICAL_ISSUES[@]}" "${#WARNING_ISSUES[@]}" "$report_mode"
        fi
    fi
    
    exit $HEALTH_STATUS
}

# スクリプト実行
main "$@"
