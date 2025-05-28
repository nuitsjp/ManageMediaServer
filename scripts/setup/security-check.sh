#!/bin/bash
# セキュリティチェックスクリプト
# 家庭内メディアサーバーのセキュリティ状態を確認

set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗"

# 環境変数読み込み
load_environment

# セキュリティチェック
main() {
    log_info "=== 家庭内メディアサーバー セキュリティチェック ==="
    
    check_firewall_status
    check_ssh_security
    check_fail2ban_status
    check_system_updates
    check_docker_security
    check_service_exposure
    check_log_monitoring
    
    log_success "=== セキュリティチェック完了 ==="
}

# ファイアウォール状態確認
check_firewall_status() {
    log_info "=== ファイアウォール状態確認 ==="
    
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status=$(sudo ufw status 2>/dev/null || echo "inactive")
        if echo "$ufw_status" | grep -q "Status: active"; then
            log_success "UFW ファイアウォールが有効です"
            
            # ポート制限確認
            if echo "$ufw_status" | grep -q "192.168"; then
                log_success "ローカルネットワーク制限が適用されています"
            else
                log_warning "ローカルネットワーク制限が設定されていない可能性があります"
            fi
        else
            log_error "UFW ファイアウォールが無効です"
        fi
    else
        log_warning "UFW がインストールされていません"
    fi
}

# SSH セキュリティ確認
check_ssh_security() {
    log_info "=== SSH セキュリティ確認 ==="
    
    if [ -f /etc/ssh/sshd_config ]; then
        # root ログイン確認
        if grep -q "PermitRootLogin no" /etc/ssh/sshd_config; then
            log_success "root SSH ログインが無効化されています"
        else
            log_warning "root SSH ログインが有効になっている可能性があります"
        fi
        
        # 認証試行制限確認
        if grep -q "MaxAuthTries" /etc/ssh/sshd_config; then
            local max_tries=$(grep "MaxAuthTries" /etc/ssh/sshd_config | awk '{print $2}')
            log_success "SSH 認証試行制限: $max_tries 回"
        else
            log_warning "SSH 認証試行制限が設定されていません"
        fi
    else
        log_warning "SSH 設定ファイルが見つかりません"
    fi
}

# fail2ban 状態確認
check_fail2ban_status() {
    log_info "=== fail2ban 状態確認 ==="
    
    if command -v fail2ban-client >/dev/null 2>&1; then
        if systemctl is-active --quiet fail2ban; then
            log_success "fail2ban サービスが動作中です"
            
            # SSH jail 確認
            local ssh_status=$(sudo fail2ban-client status sshd 2>/dev/null || echo "disabled")
            if echo "$ssh_status" | grep -q "Currently banned"; then
                local banned_count=$(echo "$ssh_status" | grep "Currently banned" | awk '{print $4}')
                log_info "現在ブロック中のIP数: $banned_count"
            fi
        else
            log_error "fail2ban サービスが停止しています"
        fi
    else
        log_warning "fail2ban がインストールされていません"
    fi
}

# システム更新状態確認
check_system_updates() {
    log_info "=== システム更新状態確認 ==="
    
    # セキュリティアップデート確認
    local security_updates=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
    if [ "$security_updates" -eq 0 ]; then
        log_success "セキュリティアップデートは最新です"
    else
        log_warning "セキュリティアップデートが $security_updates 件あります"
    fi
    
    # 自動更新確認
    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
        log_success "自動セキュリティ更新が有効です"
    else
        log_warning "自動セキュリティ更新が無効です"
    fi
}

# Docker セキュリティ確認
check_docker_security() {
    log_info "=== Docker セキュリティ確認 ==="
    
    if command -v docker >/dev/null 2>&1; then
        # Docker daemon 設定確認
        if docker info 2>/dev/null | grep -q "Security Options"; then
            log_success "Docker セキュリティ機能が有効です"
        fi
        
        # 実行中コンテナの権限確認
        local privileged_containers=$(docker ps --format "table {{.Names}}\t{{.Command}}" | grep -i privileged | wc -l || echo "0")
        if [ "$privileged_containers" -eq 0 ]; then
            log_success "特権モードで実行中のコンテナはありません"
        else
            log_warning "特権モードで実行中のコンテナが $privileged_containers 個あります"
        fi
    else
        log_warning "Docker がインストールされていません"
    fi
}

# サービス公開状態確認
check_service_exposure() {
    log_info "=== サービス公開状態確認 ==="
    
    # 外部からアクセス可能なポート確認
    local exposed_ports=$(ss -tuln | grep -E "0\.0\.0\.0:(2283|8096)" | wc -l)
    if [ "$exposed_ports" -eq 0 ]; then
        log_success "メディアサーバーポートは外部に公開されていません"
    else
        log_warning "メディアサーバーポートが外部に公開されています"
        ss -tuln | grep -E "0\.0\.0\.0:(2283|8096)" | sed 's/^/  /'
    fi
}

# ログ監視状態確認
check_log_monitoring() {
    log_info "=== ログ監視状態確認 ==="
    
    # 最近の認証失敗ログ確認
    local auth_failures=$(sudo journalctl -u ssh --since "24 hours ago" | grep -i "failed\|invalid" | wc -l)
    if [ "$auth_failures" -eq 0 ]; then
        log_success "過去24時間でSSH認証失敗はありません"
    else
        log_warning "過去24時間でSSH認証失敗が $auth_failures 回あります"
    fi
    
    # システムエラーログ確認
    local system_errors=$(sudo journalctl --priority=err --since "24 hours ago" | wc -l)
    if [ "$system_errors" -eq 0 ]; then
        log_success "過去24時間でシステムエラーはありません"
    else
        log_warning "過去24時間でシステムエラーが $system_errors 件あります"
    fi
}

# 実行
main "$@"
