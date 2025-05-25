#!/bin/bash
# 本番環境（Ubuntu Server）セットアップスクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/env-loader.sh" || log_error "env-loader.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗"

# 環境変数読み込み
load_environment

# 本番環境チェック
check_production_environment() {
    # WSL環境でないことを確認
    if is_wsl; then
        log_error "このスクリプトは本番環境（Ubuntu Server）用です。WSL環境では setup-dev.sh を使用してください"
    fi
    
    # Ubuntu環境確認
    if [ ! -f /etc/os-release ] || ! grep -q "Ubuntu" /etc/os-release; then
        log_error "Ubuntu OS が検出されませんでした"
    fi
    
    # Ubuntu 24.04 確認
    if ! grep -q "24.04" /etc/os-release; then
        log_warning "Ubuntu 24.04 LTS以外のバージョンが検出されました"
        log_info "動作確認済み: Ubuntu 24.04 LTS"
    fi
    
    log_success "本番環境（Ubuntu Server）を確認しました"
}

# ユーザー・権限確認
check_user_permissions() {
    log_info "=== ユーザー・権限確認 ==="
    
    # root実行チェック
    if [ "$(id -u)" = "0" ]; then
        log_warning "rootユーザーで実行されています"
        log_info "本番環境では専用ユーザー（mediaserver）での実行を推奨します"
        
        # mediaserverユーザー作成確認
        if ! id "mediaserver" &>/dev/null; then
            log_info "mediaserver ユーザーを作成しますか？"
            if confirm_action "mediaserver ユーザーを作成しますか？"; then
                create_mediaserver_user
            fi
        fi
    fi
    
    # sudo権限確認
    if ! sudo -n true 2>/dev/null; then
        log_error "sudo権限が必要です。現在のユーザーがsudoグループに属していることを確認してください"
    fi
    
    log_success "ユーザー・権限確認完了"
}

# mediaserverユーザー作成
create_mediaserver_user() {
    log_info "mediaserver ユーザーを作成中..."
    
    # ユーザー作成
    useradd -m -s /bin/bash mediaserver
    
    # sudoグループに追加
    usermod -aG sudo mediaserver
    
    # ホームディレクトリ権限設定
    chown mediaserver:mediaserver /home/mediaserver
    chmod 755 /home/mediaserver
    
    log_success "mediaserver ユーザーを作成しました"
    log_warning "以下のコマンドでmediaserverユーザーに切り替えてから再実行してください:"
    log_info "sudo -u mediaserver -i"
    log_info "cd $PROJECT_ROOT && ./scripts/setup/setup-prod.sh"
    exit 0
}

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

# systemdサービス設定
setup_systemd_services() {
    log_info "=== systemdサービス設定 ==="
    
    # rclone同期サービス作成
    create_rclone_sync_service
    
    # Docker Compose用systemdサービス作成
    create_docker_compose_service
    
    # タイマー設定
    setup_systemd_timers
    
    log_success "systemdサービス設定完了"
}

# rclone同期systemdサービス作成
create_rclone_sync_service() {
    log_info "rclone同期サービスを作成中..."
    
    # サービスファイル作成
    cat << EOF | sudo tee "$SYSTEMD_CONFIG_PATH/rclone-sync.service"
[Unit]
Description=rclone sync media files
After=network.target

[Service]
Type=oneshot
User=$(whoami)
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
    
    # Immichサービス
    cat << EOF | sudo tee "$SYSTEMD_CONFIG_PATH/immich.service"
[Unit]
Description=Immich Media Server
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$(whoami)
WorkingDirectory=$PROJECT_ROOT
ExecStart=/usr/bin/docker compose -f docker/prod/immich/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f docker/prod/immich/docker-compose.yml down
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # Jellyfinサービス
    cat << EOF | sudo tee "$SYSTEMD_CONFIG_PATH/jellyfin.service"
[Unit]
Description=Jellyfin Media Server
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$(whoami)
WorkingDirectory=$PROJECT_ROOT
ExecStart=/usr/bin/docker compose -f docker/prod/jellyfin/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f docker/prod/jellyfin/docker-compose.yml down
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
    
    # rclone同期タイマー（毎時実行）
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
    
    # systemdサービス・タイマー有効化
    sudo systemctl daemon-reload
    sudo systemctl enable rclone-sync.timer
    
    log_success "systemdタイマー設定完了"
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

    # 本番環境チェック
    check_production_environment

    # ユーザー・権限確認
    check_user_permissions

    # --- インストール処理は auto-setup.sh 側で実施済み ---
    setup_disk_configuration

    setup_systemd_services
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
