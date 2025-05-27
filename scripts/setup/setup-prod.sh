#!/bin/bash
# 本番環境（Ubuntu Server）セットアップスクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/rclone.sh" || log_error "rclone.sh の読み込みに失敗"

# 環境変数読み込み
load_environment

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

# ファイアウォール設定
setup_firewall() {
    log_info "=== ファイアウォール設定 ==="
    
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

# セキュリティ設定
setup_security() {
    log_info "=== セキュリティ設定 ==="
    
    # fail2ban設定
    setup_fail2ban
    
    # SSH設定強化
    setup_ssh_security
    
    # 自動更新設定
    setup_automatic_updates
    
    log_success "セキュリティ設定完了"
}

# fail2ban設定
setup_fail2ban() {
    log_info "fail2ban設定を適用中..."
    
    # fail2ban設定ファイル作成
    cat << EOF | sudo tee /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
EOF
    
    # fail2banサービス有効化
    sudo systemctl enable fail2ban
    sudo systemctl restart fail2ban
    
    log_success "fail2ban設定完了"
}

# SSH設定強化
setup_ssh_security() {
    log_info "SSH設定を強化中..."
    
    # SSH設定バックアップ
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    # SSH設定更新（基本的な強化）
    sudo sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
    sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    
    # SSH再起動
    sudo systemctl restart ssh
    
    log_success "SSH設定強化完了"
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

# メイン処理
main() {
    local force=false

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
            *)
                log_error "不明なオプション: $1"
                ;;
        esac
        shift
    done
    
    log_info "=== 本番環境（Ubuntu Server）セットアップ開始 ==="

    # --- インストール処理は auto-setup.sh 側で実施済み ---
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
