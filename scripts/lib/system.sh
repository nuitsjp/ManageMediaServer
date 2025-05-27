#!/bin/bash
# システム層ライブラリ（OS操作・チェック・セットアップ）

# 事前チェック
pre_check() {
    local env_type=$1
    
    log_info "=== 事前チェック ==="
    
    # OS バージョンチェック
    if [ "$env_type" = "prod" ]; then
        if ! grep -q "24.04" /etc/os-release 2>/dev/null; then
            log_warning "Ubuntu 24.04 LTS以外のOSが検出されました"
            log_info "対応OS: Ubuntu 24.04 LTS"
        fi
    fi
    
    # 必要なコマンドチェック
    local required_commands=("curl" "git")
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            log_error "必要なコマンドがインストールされていません: $cmd"
        fi
    done
    
    # 権限チェック
    if [ "$env_type" = "prod" ] && [ "$(id -u)" = "0" ]; then
        log_warning "rootユーザーで実行されています"
        log_info "本番環境では一般ユーザーでの実行を推奨します"
    fi
    
    # ディスク容量チェック
    local available_space=$(df "$HOME" | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 5242880 ]; then  # 5GB
        log_warning "ディスク容量が不足している可能性があります（推奨: 5GB以上）"
    fi
    
    log_success "事前チェック完了"
}

# 環境チェック（WSL または Ubuntu Server）
check_environment() {
    local env_type=$1
    if [ "$env_type" = "prod" ]; then
        if is_wsl; then
            log_error "本番環境（Ubuntu Server）用です。WSLでは実行できません"
        fi
        if [ ! -f /etc/os-release ] || ! grep -q "Ubuntu" /etc/os-release; then
            log_error "Ubuntu OS が検出されませんでした"
        fi
    else
        if ! is_wsl; then
            log_error "開発環境（WSL）用です。WSL上で実行してください"
        fi
    fi
    log_success "環境チェック完了: $env_type"
}

# ユーザー・権限確認（mediaserverユーザー作成のみ）
check_user_permissions() {
    log_info "=== ユーザー・権限確認 ==="
    if ! id mediaserver &>/dev/null; then
        log_info "mediaserver ユーザーを作成中..."
        useradd -m -s /bin/bash mediaserver
        usermod -aG docker,sudo mediaserver
        chown mediaserver:mediaserver /home/mediaserver
        chmod 755 /home/mediaserver
        log_success "mediaserver ユーザーを作成しました"
    else
        log_success "mediaserver ユーザーは既に存在します"
    fi
}

# ディレクトリ準備
prepare_directories() {
    log_info "=== ディレクトリ準備 ==="
    
    # 基本ディレクトリ作成
    local dirs=(
        "$DATA_ROOT"
        "$BACKUP_ROOT"
        "$DATA_ROOT/immich/upload"
        "$DATA_ROOT/immich/external"
        "$DATA_ROOT/immich/postgres"
        "$DATA_ROOT/jellyfin/config"
        "$DATA_ROOT/jellyfin/movies"
        "$DATA_ROOT/config/rclone"
        "$DATA_ROOT/temp"
        "$BACKUP_ROOT/media"
        "$BACKUP_ROOT/config"
    )
    
    for dir in "${dirs[@]}"; do
        ensure_dir_exists "$dir"
    done
    
    # 権限設定
    chmod 755 "$DATA_ROOT" "$BACKUP_ROOT"
    chmod 750 "$DATA_ROOT/config" "$BACKUP_ROOT/config"
    
    log_success "ディレクトリ準備完了"

    # データディレクトリをmediaserver所有に
    chown -R mediaserver:mediaserver "$DATA_ROOT" "$BACKUP_ROOT"
}

# システムパッケージ更新・インストール
install_system_packages() {
    log_info "=== システムパッケージの更新・インストール ==="
    
    # パッケージリスト更新
    apt update -y
    
    # 基本パッケージインストール
    local packages=(
        "curl"
        "git"
        "lsb-release"
        "sudo"
        "ca-certificates"
        "gnupg"
        "unzip"
    )
    
    # WSLの場合、追加のパッケージをインストール
    if is_wsl; then
        packages+=(
            "apt-transport-https"
            "software-properties-common"
        )
    fi
    
    # パッケージインストール
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -qw "$pkg"; then
            apt install -y "$pkg"
        fi
    done
    
    log_success "システムパッケージの更新・インストールが完了しました"
}
