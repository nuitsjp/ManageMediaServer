#!/bin/bash
# 本番環境（Ubuntu Server）セットアップスクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/rclone.sh" || log_error "rclone.sh の読み込みに失敗"

# ディスク構成確認・セットアップ
setup_disk_configuration() {
    log_info "=== ディスク構成確認・セットアップ ==="
    
    # /mnt/data マウントポイント確認
    if ! mountpoint -q /mnt/data 2>/dev/null; then
        log_warning "/mnt/data がマウントされていません"
        log_info "ディスク構成については docs/design/server-configuration.md を参照してください"
        
        # データディレクトリが存在しない場合は作成
        if [ ! -d "$DATA_ROOT" ]; then
            log_info "データディレクトリを作成します: $DATA_ROOT"
            sudo mkdir -p "$DATA_ROOT"
            sudo chown $(whoami):$(whoami) "$DATA_ROOT"
        fi
    else
        log_success "/mnt/data マウント確認完了"
    fi
    
    # /mnt/backup マウントポイント確認
    if ! mountpoint -q /mnt/backup 2>/dev/null; then
        log_warning "/mnt/backup がマウントされていません"
        
        # バックアップディレクトリが存在しない場合は作成
        if [ ! -d "$BACKUP_ROOT" ]; then
            log_info "バックアップディレクトリを作成します: $BACKUP_ROOT"
            sudo mkdir -p "$BACKUP_ROOT"
            sudo chown $(whoami):$(whoami) "$BACKUP_ROOT"
        fi
    else
        log_success "/mnt/backup マウント確認完了"
    fi
    
    log_success "ディスク構成セットアップ完了"
}

# ファイアウォール設定（テストモード対応）
setup_firewall() {
    log_info "=== ファイアウォール設定 ==="
    
    # テストモード時の動作
    if [ "${TEST_MODE:-false}" = "true" ]; then
        log_info "[テストモード] ファイアウォール設定をシミュレーション実行中..."
        log_info "[SKIP] sudo ufw --force reset"
        log_info "[SKIP] sudo ufw default deny incoming"
        log_info "[SKIP] sudo ufw default allow outgoing"
        log_info "[SKIP] sudo ufw allow ssh"
        log_info "[SKIP] sudo ufw allow from 192.168.0.0/16 to any port 2283 comment 'Immich'"
        log_info "[SKIP] sudo ufw allow from 192.168.0.0/16 to any port 8096 comment 'Jellyfin'"
        log_info "[SKIP] sudo ufw --force enable"
        log_warning "[テストモード] 実際のファイアウォール設定は実行されていません"
        return 0
    fi
    
    # UFW初期化
    sudo ufw --force reset
    
    # デフォルトポリシー設定
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # SSH許可
    sudo ufw allow ssh
    
    # ローカルネットワークからのアクセス許可
    sudo ufw allow from 192.168.0.0/16 to any port 2283 comment 'Immich'
    sudo ufw allow from 192.168.0.0/16 to any port 8096 comment 'Jellyfin'
    
    # UFW有効化
    sudo ufw --force enable
    
    log_success "ファイアウォール設定完了"
    sudo ufw status verbose
}

# セキュリティ設定（テストモード対応）
setup_security() {
    log_info "=== セキュリティ設定 ==="
    
    # テストモード時の処理
    if [ "${TEST_MODE:-false}" = "true" ]; then
        log_info "[テストモード] セキュリティ設定をシミュレーション実行中..."
        setup_firewall
        setup_fail2ban  
        setup_ssh_security
        log_success "[テストモード] セキュリティ設定シミュレーション完了"
        log_warning "実際の設定適用は本番環境で --test-mode を外して実行してください"
        return 0
    fi
    
    # 実際のセキュリティ設定実行
    setup_firewall
    setup_fail2ban  
    setup_ssh_security
    log_success "セキュリティ設定完了"
}

# fail2ban設定（テストモード対応）
setup_fail2ban() {
    log_info "fail2ban設定を適用中..."
    
    # テストモード時の動作
    if [ "${TEST_MODE:-false}" = "true" ]; then
        log_info "[テストモード] fail2ban設定をシミュレーション実行中..."
        log_info "[SKIP] fail2banパッケージインストール"
        log_info "[SKIP] jail.local設定作成（家庭内IP 192.168.0.0/16 除外）"
        log_info "[SKIP] fail2banサービス再起動"
        log_warning "[テストモード] 実際のfail2ban設定は実行されていません"
        return 0
    fi
    
    # fail2banパッケージインストール
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        sudo apt update && sudo apt install -y fail2ban
    fi
    
    # fail2ban設定（家庭内ネットワーク除外）
    sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[DEFAULT]
# 家庭内ネットワークを除外（192.168.0.0/16全体をカバー）
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16

# ログファイル日時形式を明示的に指定
datepattern = {^LN-BEG}

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
backend = systemd
EOF
    
    # fail2banサービス再起動
    sudo systemctl restart fail2ban
    sudo systemctl enable fail2ban
    
    log_success "fail2ban設定完了（家庭内IP除外設定済み）"
    
    # 設定状態表示
    if command -v fail2ban-client >/dev/null 2>&1; then
        sudo fail2ban-client status
    fi
}

# SSH設定強化（テストモード対応）
setup_ssh_security() {
    log_info "SSH設定を強化中..."
    
    # テストモード時の動作
    if [ "${TEST_MODE:-false}" = "true" ]; then
        log_info "[テストモード] SSH設定強化をシミュレーション実行中..."
        log_info "[SKIP] PermitRootLogin no 設定"
        log_info "[SKIP] PasswordAuthentication yes 設定（家庭内アクセス考慮）"
        log_info "[SKIP] MaxAuthTries 3 設定"
        log_info "[SKIP] SSH設定テスト・サービス再起動"
        log_warning "[テストモード] 実際のSSH設定は実行されていません"
        return 0
    fi
    
    # SSH設定ファイルのバックアップ
    if [ ! -f /etc/ssh/sshd_config.backup ]; then
        sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
        log_info "SSH設定ファイルをバックアップしました"
    fi
    
    # 家庭内ネットワーク前提の基本的なSSH強化
    # 注意: パスワード認証は家庭内アクセスの利便性を考慮して維持
    sudo sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
    sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    
    # ログイン試行制限を追加
    if ! grep -q "MaxAuthTries" /etc/ssh/sshd_config; then
        echo "MaxAuthTries 3" | sudo tee -a /etc/ssh/sshd_config
    fi
    
    # SSH設定確認
    if sudo sshd -t; then
        sudo systemctl restart ssh
        log_success "SSH設定強化完了"
    else
        log_error "SSH設定にエラーがあります。バックアップから復元します"
        sudo cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        sudo systemctl restart ssh
        return 1
    fi
}

# 自動更新設定
setup_automatic_updates() {
    log_info "自動更新を設定中..."
    
    # unattended-upgradesインストール
    sudo apt install -y unattended-upgrades
    
    # 自動更新有効化
    echo 'Unattended-Upgrade::Automatic-Reboot "false";' | sudo tee -a /etc/apt/apt.conf.d/50unattended-upgrades
    
    # 自動更新サービス有効化
    sudo systemctl enable unattended-upgrades
    
    log_success "自動更新設定完了"
}

# Docker Compose設定準備（本番環境）
prepare_production_compose() {
    log_info "=== 本番Docker Compose設定準備 ==="
    
    # 本番用ディレクトリ作成
    local prod_dir="$PROJECT_ROOT/docker/prod"
    ensure_dir_exists "$prod_dir/immich"
    ensure_dir_exists "$prod_dir/jellyfin"
    
    # 設定ファイルは別途作成予定
    log_info "本番用Docker Compose設定ディレクトリを準備しました"
    log_warning "実際の設定ファイルは docker/prod/ 配下で管理します"
    
    log_success "本番Docker Compose設定準備完了"
}

# 動作確認（本番環境）
verify_production_installation() {
    log_info "=== 本番環境動作確認 ==="
    
    # Docker動作確認
    if command_exists docker; then
        log_info "Docker バージョン: $(docker --version)"
        if docker info >/dev/null 2>&1; then
            log_success "Docker は正常に動作しています"
        else
            log_warning "Docker デーモンが起動していません"
        fi
    else
        log_error "Docker のインストールに失敗しました"
    fi
    
    # rclone動作確認
    if command_exists rclone; then
        log_info "rclone バージョン: $(rclone version | head -1)"
        log_success "rclone は正常にインストールされています"
    else
        log_error "rclone のインストールに失敗しました"
    fi
    
    # systemdサービス確認
    local services=("docker" "fail2ban" "ufw")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log_success "サービス確認: $service (起動中)"
        else
            log_warning "サービス確認: $service (停止中)"
        fi
    done
    
    # ディレクトリ確認
    local dirs=("$DATA_ROOT" "$BACKUP_ROOT")
    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ]; then
            log_success "ディレクトリ確認: $dir"
        else
            log_error "ディレクトリが作成されていません: $dir"
        fi
    done
    
    log_success "本番環境動作確認完了"
}

# 使用方法表示
show_usage() {
    cat << 'EOF'
本番環境（Ubuntu Server）セットアップスクリプト

使用方法:
    ./setup-prod.sh [オプション]

オプション:
    --force             強制実行（既存設定を上書き）
    --debug             デバッグモード（詳細ログ出力）
    --security-only     セキュリティ設定のみ実行
    --test-mode         テストモード（WSL環境でセキュリティ設定をシミュレーション）
    --help              このヘルプを表示

例:
    # 通常の本番環境セットアップ
    ./setup-prod.sh

    # WSL環境でセキュリティ設定をテスト
    ./setup-prod.sh --test-mode --security-only

    # 本番環境でセキュリティ設定のみ適用
    ./setup-prod.sh --security-only

注意:
    - 本スクリプトは家庭内クローズドネットワーク環境を前提としています
    - --test-mode はWSL環境でのセキュリティ設定事前確認用です
    - 実際のセキュリティ設定は本番環境で --test-mode を外して実行してください

EOF
}

# メイン処理
main() {
    local force=false
    local security_only=false
    local test_mode=false

    # 引数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force=true
                export FORCE=true
                ;;
            --debug)
                export DEBUG=1
                ;;
            --security-only)
                security_only=true
                ;;
            --test-mode)
                test_mode=true
                log_info "テストモード有効: WSL環境でのセキュリティ設定をシミュレーション実行"
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
    
    # テストモード設定
    if [ "$test_mode" = "true" ]; then
        export TEST_MODE=true
    fi

    log_info "=== 本番環境セットアップ開始 ==="
    
    if [ "$test_mode" = "true" ]; then
        log_warning "テストモード実行中: セキュリティ設定はシミュレーションのみ"
    fi

    # 環境設定読み込み
    load_environment

    # セキュリティ専用実行時
    if [ "$security_only" = "true" ]; then
        log_info "セキュリティ設定のみ実行します"
        setup_security
        log_success "セキュリティ設定完了"
        exit 0
    fi

    # 事前チェック
    pre_check "prod"

    # ディスク構成確認・セットアップ
    setup_disk_configuration
    setup_firewall
    setup_security
    prepare_production_compose

    # 動作確認
    verify_production_installation

    log_success "=== 本番環境セットアップ完了 ==="
    
    # 次のステップ案内
    cat << EOF

次のステップ:
1. Docker Compose設定ファイル作成:
   - $PROJECT_ROOT/docker/prod/immich/docker-compose.yml
   - $PROJECT_ROOT/docker/prod/jellyfin/docker-compose.yml

2. rclone設定:
   rclone config

3. サービス起動:
   sudo systemctl start immich
   sudo systemctl start jellyfin

4. Cloudflare Tunnel設定（外部アクセス用）

5. バックアップ設定

詳細は docs/operations/README.md を参照してください。
EOF
}

# スクリプト実行
main "$@"
