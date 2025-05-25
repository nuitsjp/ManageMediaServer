#!/bin/bash
# システム更新スクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/env-loader.sh" || log_error "env-loader.sh の読み込みに失敗"

# 環境変数読み込み
load_environment

# 使用方法表示
show_usage() {
    cat << EOF
使用方法: $0 [オプション]

システムパッケージとDockerコンテナの更新を安全に実行します。

オプション:
    --security-only  セキュリティアップデートのみ適用
    --with-restart   更新後にシステム再起動
    --docker-only    Dockerコンテナのみ更新
    --system-only    システムパッケージのみ更新
    --dry-run        実際の更新は行わず、更新予定パッケージのみ表示
    --auto           確認をスキップして自動実行
    --help           このヘルプを表示

例:
    ./update-system.sh                    # 通常の更新
    ./update-system.sh --security-only    # セキュリティ更新のみ
    ./update-system.sh --dry-run          # 更新予定確認
    ./update-system.sh --docker-only      # Docker更新のみ

EOF
}

# システム更新前チェック
pre_update_check() {
    log_info "=== システム更新前チェック ==="
    
    # 本番環境確認
    if is_wsl; then
        log_error "本番環境（Ubuntu Server）でのみ実行可能です"
    fi
    
    # ディスク容量確認
    local root_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$root_usage" -gt 90 ]; then
        log_error "ルートファイルシステムの容量が不足しています: ${root_usage}%"
    fi
    
    # 実行中のサービス確認
    log_info "重要サービスの状態確認:"
    local services=("docker" "immich" "jellyfin" "ssh")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "  $service: 動作中"
        else
            log_warning "  $service: 停止中"
        fi
    done
    
    # システム負荷確認
    local load_avg=$(uptime | awk -F'load average:' '{ print $2 }' | awk '{ print $1 }' | sed 's/,//')
    log_info "システム負荷: $load_avg"
    
    log_success "システム更新前チェック完了"
}

# システムパッケージ更新
update_system_packages() {
    local security_only=$1
    
    log_info "=== システムパッケージ更新 ==="
    
    # パッケージリスト更新
    log_info "パッケージリストを更新中..."
    sudo apt update
    
    # 更新可能パッケージ確認
    local update_count=$(apt list --upgradable 2>/dev/null | wc -l)
    log_info "更新可能パッケージ数: $((update_count - 1))"
    
    if [ "$security_only" = "true" ]; then
        log_info "セキュリティ更新を適用中..."
        sudo apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
        sudo unattended-upgrade -d
    else
        log_info "全パッケージを更新中..."
        sudo apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
        
        # 不要パッケージ削除
        log_info "不要パッケージを削除中..."
        sudo apt autoremove -y
        sudo apt autoclean
    fi
    
    log_success "システムパッケージ更新完了"
}

# Docker更新
update_docker_containers() {
    log_info "=== Dockerコンテナ更新 ==="
    
    # 現在のコンテナ状態を記録
    local containers_info=$(docker ps --format "{{.Names}}:{{.Image}}" 2>/dev/null || echo "")
    log_info "更新前のコンテナ状態:"
    echo "$containers_info"
    
    # サービス停止
    log_info "Dockerサービスを一時停止中..."
    systemctl stop immich jellyfin 2>/dev/null || true
    
    # イメージ更新
    cd "$PROJECT_ROOT"
    
    # Immichイメージ更新
    if [ -f "docker/immich/docker-compose.yml" ]; then
        log_info "Immichイメージを更新中..."
        docker compose -f docker/immich/docker-compose.yml pull
    fi
    
    # Jellyfinイメージ更新
    if [ -f "docker/jellyfin/docker-compose.yml" ]; then
        log_info "Jellyfinイメージを更新中..."
        docker compose -f docker/jellyfin/docker-compose.yml pull
    fi
    
    # 未使用イメージ削除
    log_info "未使用Dockerイメージを削除中..."
    docker image prune -f
    
    # サービス再起動
    log_info "Dockerサービスを再起動中..."
    systemctl start immich jellyfin
    
    # 更新後の確認
    sleep 10
    log_info "更新後のコンテナ状態:"
    docker ps --format "{{.Names}}:{{.Image}}"
    
    log_success "Dockerコンテナ更新完了"
}

# システム状態確認
verify_system_state() {
    log_info "=== システム状態確認 ==="
    
    # サービス状態確認
    local services=("docker" "immich" "jellyfin" "ssh")
    local failed_services=()
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_success "サービス確認: $service (正常動作)"
        else
            log_error "サービス確認: $service (動作異常)"
            failed_services+=("$service")
        fi
    done
    
    # ディスク容量確認
    log_info "ディスク使用量:"
    df -h / "$DATA_ROOT" "$BACKUP_ROOT" 2>/dev/null || true
    
    # メモリ使用量確認
    log_info "メモリ使用量:"
    free -h
    
    # システム負荷確認
    log_info "システム負荷:"
    uptime
    
    # Docker コンテナ確認
    log_info "Dockerコンテナ状態:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    # アプリケーション確認
    log_info "アプリケーション動作確認:"
    
    # Immichヘルスチェック
    if curl -f http://localhost:2283/api/server-info/ping >/dev/null 2>&1; then
        log_success "Immich: 正常動作"
    else
        log_warning "Immich: 応答なし"
        failed_services+=("immich-app")
    fi
    
    # Jellyfinヘルスチェック
    if curl -f http://localhost:8096/health >/dev/null 2>&1; then
        log_success "Jellyfin: 正常動作"
    else
        log_warning "Jellyfin: 応答なし"
        failed_services+=("jellyfin-app")
    fi
    
    # 結果判定
    if [ ${#failed_services[@]} -eq 0 ]; then
        log_success "システム状態確認: 全て正常"
        return 0
    else
        log_warning "システム状態確認: 以下で問題が検出されました: ${failed_services[*]}"
        return 1
    fi
}

# 再起動が必要かチェック
check_reboot_required() {
    if [ -f /var/run/reboot-required ]; then
        log_warning "システム再起動が必要です"
        if [ -f /var/run/reboot-required.pkgs ]; then
            log_info "再起動が必要なパッケージ:"
            cat /var/run/reboot-required.pkgs
        fi
        return 0
    else
        log_info "システム再起動は不要です"
        return 1
    fi
}

# システム再起動
perform_reboot() {
    log_warning "システムを再起動します"
    log_info "再起動後、サービスの自動起動を確認してください"
    
    # サービス停止
    log_info "サービスを安全に停止中..."
    systemctl stop immich jellyfin 2>/dev/null || true
    
    # 再起動実行
    log_info "5秒後にシステムを再起動します..."
    sleep 5
    sudo reboot
}

# 更新ログ記録
log_update_history() {
    local update_type=$1
    local log_file="$BACKUP_ROOT/update_history.log"
    
    echo "========================================" >> "$log_file"
    echo "Update Date: $(date '+%Y-%m-%d %H:%M:%S')" >> "$log_file"
    echo "Update Type: $update_type" >> "$log_file"
    echo "User: $(whoami)" >> "$log_file"
    echo "Git Commit: $(git rev-parse HEAD 2>/dev/null || echo 'unknown')" >> "$log_file"
    echo "System Info: $(uname -a)" >> "$log_file"
    echo "----------------------------------------" >> "$log_file"
}

# メイン処理
main() {
    local security_only=false
    local with_restart=false
    local docker_only=false
    local system_only=false
    local dry_run=false
    local auto=false
    
    # 引数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            --security-only)
                security_only=true
                ;;
            --with-restart)
                with_restart=true
                ;;
            --docker-only)
                docker_only=true
                ;;
            --system-only)
                system_only=true
                ;;
            --dry-run)
                dry_run=true
                ;;
            --auto)
                auto=true
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
    
    log_info "=== システム更新スクリプト開始 ==="
    
    # ドライラン
    if [ "$dry_run" = "true" ]; then
        log_info "=== ドライラン: 更新可能項目 ==="
        
        if [ "$docker_only" != "true" ]; then
            log_info "システムパッケージ更新予定:"
            apt list --upgradable 2>/dev/null | head -20
        fi
        
        if [ "$system_only" != "true" ]; then
            log_info "Docker更新予定:"
            cd "$PROJECT_ROOT"
            docker compose -f docker/immich/docker-compose.yml pull --dry-run 2>/dev/null || echo "Immich: 更新確認不可"
            docker compose -f docker/jellyfin/docker-compose.yml pull --dry-run 2>/dev/null || echo "Jellyfin: 更新確認不可"
        fi
        
        exit 0
    fi
    
    # 更新実行確認
    if [ "$auto" != "true" ]; then
        log_warning "システム更新を実行します"
        if ! confirm_action "続行しますか？"; then
            log_info "システム更新をキャンセルしました"
            exit 0
        fi
    fi
    
    # 更新処理実行
    pre_update_check
    
    local update_type="full"
    
    if [ "$docker_only" = "true" ]; then
        update_type="docker-only"
        update_docker_containers
    elif [ "$system_only" = "true" ]; then
        update_type="system-only"
        update_system_packages "$security_only"
    else
        update_type="full"
        update_system_packages "$security_only"
        update_docker_containers
    fi
    
    # 更新後確認
    verify_system_state
    
    # 履歴記録
    log_update_history "$update_type"
    
    # 再起動確認
    if [ "$with_restart" = "true" ] || check_reboot_required; then
        if [ "$auto" = "true" ] || confirm_action "システムを再起動しますか？"; then
            perform_reboot
        fi
    fi
    
    log_success "=== システム更新完了 ==="
}

# スクリプト実行
main "$@"
