#!/bin/bash
# --- root権限チェック・昇格 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "[INFO] Root権限が必要です。sudoで再実行します..."
    exec sudo bash "$0" "$@"
fi
# --------------------------------

# 統合セットアップスクリプト（環境自動判定）
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/env-loader.sh" || log_error "env-loader.sh の読み込みに失敗"

# ヘルプ表示
show_help() {
    cat << EOF
家庭用メディアサーバー自動セットアップスクリプト

使用法:
    $0 [オプション]

オプション:
    --help, -h      このヘルプを表示
    --debug         デバッグモード（詳細ログ表示）
    --force         既存設定を強制上書き
    --dry-run       実際の実行は行わず、実行予定の処理のみ表示

説明:
    このスクリプトは実行環境を自動判定し、適切なセットアップを実行します：
    - WSL環境: 開発環境として構築
    - Ubuntu Server: 本番環境として構築

例:
    ./auto-setup.sh                # 標準セットアップ
    ./auto-setup.sh --debug        # デバッグモードでセットアップ
    ./auto-setup.sh --dry-run      # 実行予定の処理を確認
EOF
}

# 環境情報表示
show_environment_info() {
    local env_type=$1
    
    log_info "=== 環境情報 ==="
    
    case "$env_type" in
        "dev")
            cat << EOF
検出環境: 開発環境（WSL）
OS: $(grep -E "(Microsoft|WSL)" /proc/version 2>/dev/null | head -1)
セットアップ対象:
  - PROJECT_ROOT: $PROJECT_ROOT
  - DATA_ROOT: $DATA_ROOT  
  - BACKUP_ROOT: $BACKUP_ROOT
  - Docker CE (WSL内ネイティブ)
  - Immich（開発用設定）
  - Jellyfin（開発用設定）
  - rclone（テスト設定）
EOF
            ;;
        "prod")
            cat << EOF
検出環境: 本番環境（Ubuntu Server）
OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
セットアップ対象:
  - PROJECT_ROOT: $PROJECT_ROOT
  - DATA_ROOT: $DATA_ROOT
  - BACKUP_ROOT: $BACKUP_ROOT
  - システムサービス
  - セキュリティ設定
  - ファイアウォール設定
EOF
            ;;
        *)
            log_warning "未対応の環境です。手動セットアップが必要です。"
            log_info "対応環境: WSL2 (Ubuntu) / Ubuntu Server 24.04 LTS"
            return 1
            ;;
    esac
    
    echo
}

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

# 設定ファイル展開
deploy_config_files() {
    log_info "=== 設定ファイル展開 ==="
    
    # Docker Composeファイル作成
    create_docker_compose_files
    
    # Jellyfin .envファイル生成
    generate_jellyfin_env
    
    # シェル環境に環境変数設定を追加
    setup_shell_environment
    
    log_success "設定ファイル展開完了"
}

# Docker Composeファイル作成
create_docker_compose_files() {
    local env_type=$(detect_environment)
    
    log_info "Docker Composeファイルを作成中..."
    
    # 統一パス構成に基づいて作成
    create_immich_docker_compose
    create_jellyfin_docker_compose
    
    log_success "Docker Composeファイル作成完了"
}

# Immich用Docker Composeファイル作成
create_immich_docker_compose() {
    local compose_file="$PROJECT_ROOT/docker/immich/docker-compose.yml"
    local env_file="$PROJECT_ROOT/docker/immich/.env"
    local compose_dir="$(dirname "$compose_file")"
    
    # ディレクトリ作成
    ensure_dir_exists "$compose_dir"
    
    # 既存ファイルがない場合、または強制更新の場合
    if [ ! -f "$compose_file" ] || [ ! -f "$env_file" ] || [ "${FORCE:-false}" = "true" ]; then
        log_info "Immich公式設定ファイルをダウンロード中..."
        
        # 作業ディレクトリに移動
        cd "$compose_dir"
        
        # 公式ファイルダウンロード
        if wget -O docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml; then
            log_success "docker-compose.yml をダウンロードしました"
        else
            log_error "docker-compose.yml のダウンロードに失敗しました"
            return 1
        fi
        
        if wget -O .env https://github.com/immich-app/immich/releases/latest/download/example.env; then
            log_success ".env をダウンロードしました"
        else
            log_error ".env のダウンロードに失敗しました"
            return 1
        fi
        
        # 外部ライブラリパスを追加
        add_external_library_path "$compose_file"
        
        # .envファイルを環境に応じて調整
        configure_immich_env "$env_file"
        
        log_success "Immich設定ファイルの準備が完了しました"
    else
        log_info "Immich設定ファイルは既に存在します"
        
        # 外部ライブラリパスが追加されているか確認
        if ! grep -q "EXTERNAL_PATH" "$compose_file"; then
            log_info "外部ライブラリパスを追加中..."
            add_external_library_path "$compose_file"
        fi
    fi
}

# 外部ライブラリパスをdocker-compose.ymlに追加
add_external_library_path() {
    local compose_file="$1"
    
    log_info "外部ライブラリパスを追加中..."
    
    # /etc/localtime:/etc/localtime:ro の後に外部ライブラリパスを追加
    sed -i '/- \/etc\/localtime:\/etc\/localtime:ro/a\      # External library support\n      - ${EXTERNAL_PATH:-/tmp/empty}:/usr/src/app/external:ro' "$compose_file"
    
    log_success "外部ライブラリパスを追加しました"
}

# Immich .envファイルの環境調整
configure_immich_env() {
    local env_file="$1"
    local env_type=$(detect_environment)
    
    log_info "Immich .envファイルを環境に応じて設定中..."
    
    # 環境変数のパスを設定
    if [ "$env_type" = "dev" ]; then
        # 開発環境用パス設定
        sed -i "s|UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${DATA_ROOT}/immich/upload|" "$env_file"
        sed -i "s|#EXTERNAL_PATH=.*|EXTERNAL_PATH=${DATA_ROOT}/immich/external|" "$env_file"
        
        # データベース設定
        sed -i "s|DB_DATA_LOCATION=.*|DB_DATA_LOCATION=${DATA_ROOT}/immich/postgres|" "$env_file"
    else
        # 本番環境用パス設定
        sed -i "s|UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${DATA_ROOT}/immich/upload|" "$env_file"
        sed -i "s|#EXTERNAL_PATH=.*|EXTERNAL_PATH=${DATA_ROOT}/immich/external|" "$env_file"
        sed -i "s|DB_DATA_LOCATION=.*|DB_DATA_LOCATION=${DATA_ROOT}/immich/postgres|" "$env_file"
    fi
    
    # EXTERNAL_PATHのコメントアウトを解除
    sed -i 's/^#EXTERNAL_PATH=/EXTERNAL_PATH=/' "$env_file"
    
    log_success "Immich .envファイルの設定が完了しました"
}

# Jellyfin用Docker Composeファイル作成
create_jellyfin_docker_compose() {
    local compose_file="$PROJECT_ROOT/docker/jellyfin/docker-compose.yml"
    local compose_dir="$(dirname "$compose_file")"
    
    # ディレクトリ作成
    ensure_dir_exists "$compose_dir"
    
    # 既存の公式ファイルがある場合は保持（.env不要）
    if [ -f "$compose_file" ]; then
        log_success "Jellyfin用Docker Composeファイルは既に存在します（公式ファイル使用）: $compose_file"
        log_info "Jellyfinは.envファイルを使用せず、公式ファイルをそのまま利用します"
        return 0
    fi
    
    # ファイルが存在しない場合はエラー（公式ファイル配置を前提）
    log_error "Jellyfin用Docker Composeファイルが見つかりません: $compose_file"
    log_info "公式のdocker-compose.ymlファイルを配置してください"
    log_info "参考: https://jellyfin.org/docs/general/installation/container"
    return 1
}

# Jellyfin用.envファイル生成
generate_jellyfin_env() {
    # Jellyfinは.envファイルを使用しないため、何もしない
    log_info "Jellyfin設定: 公式Docker Composeファイルを使用（.env不要）"
    log_info "設定変更が必要な場合は docker/jellyfin/docker-compose.yml を直接編集してください"
}

# シェル環境設定
setup_shell_environment() {
    local env_type=$(detect_environment)
    local env_setup_file="$HOME/.media-server-env"
    
    # 環境変数設定ファイル作成
    cat > "$env_setup_file" << EOF
# MediaServer環境変数設定
# 自動生成日時: $(date '+%Y-%m-%d %H:%M:%S')

export PROJECT_ROOT="$PROJECT_ROOT"
export DATA_ROOT="$DATA_ROOT"
export BACKUP_ROOT="$BACKUP_ROOT"
export MEDIA_SERVER_ENV="$env_type"
EOF
    
    # .bashrcに追加（既に存在しない場合のみ）
    if ! grep -q "media-server-env" "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" << EOF

# MediaServer環境変数設定
if [ -f "\$HOME/.media-server-env" ]; then
    source "\$HOME/.media-server-env"
fi
EOF
        log_info "環境変数設定を .bashrc に追加しました"
    fi
    
    # 開発環境用の自動起動設定は統一構成に対応
    if [ "$env_type" = "dev" ] && ! grep -q "docker compose -f docker/immich/docker-compose.yml up -d" "$HOME/.bashrc"; then
        cat >> "$HOME/.bashrc" << 'EOF'

# 開発環境起動時のサービス自動起動
if [ -f "$PROJECT_ROOT/docker/immich/docker-compose.yml" ]; then
    (cd "$PROJECT_ROOT" && docker compose -f docker/immich/docker-compose.yml up -d)
    (cd "$PROJECT_ROOT" && docker compose -f docker/jellyfin/docker-compose.yml up -d)
fi
EOF
        log_info "開発環境サービス自動起動設定を .bashrc に追加しました"
    fi
    
    # 現在のセッションに環境変数を反映
    source "$env_setup_file"
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
    )
    
    # WSLの場合、追加のパッケージをインストール
    if grep -q Microsoft /proc/version; then
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

# Docker CEインストール
install_docker() {
    log_info "=== Docker のインストール ==="
    
    # 既存の Docker および containerd パッケージを削除して競合を回避
    log_info "既存の Docker 関連パッケージを削除中..."
    apt remove -y docker docker-engine docker.io containerd containerd.io runc || true
    
    # パッケージリスト更新
    apt update -y

    # docker.io と docker-compose をインストール
    local docker_pkgs=("docker.io" "docker-compose")
    for pkg in "${docker_pkgs[@]}"; do
        if ! dpkg -l | grep -qw "$pkg"; then
            apt install -y "$pkg"
        fi
    done

    # WSL環境での追加設定
    if is_wsl; then
        setup_docker_for_wsl
    fi

    # docker グループにユーザーを追加
    usermod -aG docker "$USER"
    
    # Dockerサービス起動
    if ! systemctl start docker; then
        log_warning "systemctl でのDocker起動に失敗しました。手動起動を試行します..."
        if is_wsl; then
            # WSL環境での手動起動
            /usr/bin/dockerd --host=unix:///var/run/docker.sock --host=tcp://127.0.0.1:2375 &
            sleep 5
            if docker info >/dev/null 2>&1; then
                log_success "Docker手動起動に成功しました"
            else
                log_error "Docker起動に失敗しました。WSL設定を確認してください"
            fi
        fi
    else
        log_success "Docker サービス起動成功"
    fi
    
    log_success "Docker と docker-compose のインストール完了"
}

# WSL環境でのDocker設定
setup_docker_for_wsl() {
    log_info "WSL環境用Docker設定を適用中..."
    
    # Docker daemon設定ファイル作成
    local docker_config_dir="/etc/docker"
    local docker_config_file="$docker_config_dir/daemon.json"
    
    ensure_dir_exists "$docker_config_dir"
    
    # WSL用Docker daemon設定
    cat > "$docker_config_file" << 'EOF'
{
    "hosts": ["fd://", "tcp://127.0.0.1:2375"],
    "iptables": false,
    "bridge": "none"
}
EOF
    
    # systemd設定をWSL用に調整
    local systemd_override_dir="/etc/systemd/system/docker.service.d"
    ensure_dir_exists "$systemd_override_dir"
    
    cat > "$systemd_override_dir/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --containerd=/run/containerd/containerd.sock
EOF
    
    # systemd設定リロード
    systemctl daemon-reload
    
    log_success "WSL環境用Docker設定完了"
}

# rcloneインストール
install_rclone() {
    log_info "=== rcloneのインストール ==="
    
    # rcloneの公式GPGキーを追加
    curl https://rclone.org/install.sh | sudo bash
    
    log_success "rcloneのインストールが完了しました"
}

# systemdサービス設定（本番環境用）
setup_systemd_services() {
    log_info "=== systemdサービス設定 ==="
    create_rclone_sync_service
    create_docker_compose_service
    setup_systemd_timers
    # 本番環境: サービスをブート時に自動起動
    systemctl daemon-reload
    systemctl enable immich.service jellyfin.service rclone-sync.timer
    log_success "systemdサービス設定完了"
}

create_rclone_sync_service() {
    log_info "rclone同期サービスを作成中..."
    cat << EOF | tee "$SYSTEMD_CONFIG_PATH/rclone-sync.service"
[Unit]
Description=rclone sync media files
After=network.target

[Service]
Type=oneshot
User=mediaserver
Environment=RCLONE_CONFIG=$RCLONE_CONFIG_PATH
ExecStart=/usr/bin/rclone sync ${RCLONE_REMOTE_NAME}:/ $DATA_ROOT/immich/external --log-file=$RCLONE_LOG_PATH/sync.log --log-level INFO
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    log_success "rclone同期サービスを作成しました"
}

create_docker_compose_service() {
    log_info "Docker Compose systemdサービスを作成中..."
    local env_type=$(detect_environment)
    
    # 統一パス構成に対応
    # Immich
    cat << EOF | tee "$SYSTEMD_CONFIG_PATH/immich.service"
[Unit]
Description=Immich Media Server
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=mediaserver
WorkingDirectory=$PROJECT_ROOT
ExecStart=/usr/bin/docker compose -f $PROJECT_ROOT/docker/immich/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f $PROJECT_ROOT/docker/immich/docker-compose.yml down
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    # Jellyfin
    cat << EOF | tee "$SYSTEMD_CONFIG_PATH/jellyfin.service"
[Unit]
Description=Jellyfin Media Server
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=mediaserver
WorkingDirectory=$PROJECT_ROOT
ExecStart=/usr/bin/docker compose -f $PROJECT_ROOT/docker/jellyfin/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f $PROJECT_ROOT/docker/jellyfin/docker-compose.yml down
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    log_success "Docker Compose systemdサービスを作成しました"
}

setup_systemd_timers() {
    log_info "systemdタイマーを設定中..."
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
    sudo systemctl daemon-reload
    sudo systemctl enable rclone-sync.timer
    log_success "systemdタイマー設定完了"
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

# メイン処理
main() {
    local dry_run=false
    local force=false
    
    # 引数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --debug)
                export DEBUG=1
                log_debug "デバッグモードが有効になりました"
                ;;
            --force)
                force=true
                export FORCE=true
                log_info "強制上書きモードが有効になりました"
                ;;
            --dry-run)
                dry_run=true
                log_info "ドライランモードが有効になりました"
                ;;
            *)
                log_error "不明なオプション: $1"
                echo "ヘルプ: $0 --help"
                exit 1
                ;;
        esac
        shift
    done
    
    log_info "=== 家庭用メディアサーバー自動セットアップ開始 ==="
    
    # 環境変数読み込み（既にenv-loaderで実行済みだが明示的に）
    local env_type=$(detect_environment)

    # ← 変更: ユーザー作成のみ。切り替えは行わない
    check_user_permissions

    # 環境情報表示
    show_environment_info "$env_type"
    
    # ← ここで環境チェックを実行
    check_environment "$env_type"

    if [ "$dry_run" = "true" ]; then
        log_info "=== ドライラン: 以下の処理が実行されます ==="
        echo "1. 事前チェック"
        echo "2. ディレクトリ準備"
        echo "3. 設定ファイル展開"
        echo "4. 環境別セットアップ"
        echo "   - 環境: $env_type"
        if [ "$env_type" = "prod" ]; then
            echo "   - スクリプト: $SCRIPT_DIR/setup-prod.sh"
        else
            echo "   - 開発環境: scripts/dev にある既存スクリプトを参照してください"
        fi
        log_info "実際の実行を行う場合は --dry-run オプションを外してください"
        exit 0
    fi
    
    # 実行確認
    if [ "$force" != "true" ]; then
        log_warning "上記の設定でセットアップを実行します"
        if ! confirm_action "続行しますか？"; then
            log_info "セットアップをキャンセルしました"
            exit 0
        fi
    fi
    
    # 事前チェック
    pre_check "$env_type"

    # ディレクトリ準備
    prepare_directories

    # 設定ファイル展開
    deploy_config_files

    # ← ここから共通インストール処理を実行
    install_system_packages
    install_docker
    install_rclone

    # 環境別セットアップ
    setup_systemd_services
    if [ "$env_type" = "prod" ]; then
        log_info "=== 本番環境セットアップ ==="
        bash "$SCRIPT_DIR/setup-prod.sh" $script_args
    else
        log_info "=== 開発環境セットアップ ==="
    fi
    # サービス起動
    log_info "=== サービス起動 ==="
    systemctl start immich.service jellyfin.service

    log_success "=== 自動セットアップ完了 ==="
    
    # 次のステップ案内
    show_next_steps "$env_type"
}

# 次のステップ案内
show_next_steps() {
    local env_type=$1
    
    log_info "=== 次のステップ ==="
    
    case "$env_type" in
        "dev")
            cat << EOF
開発環境のセットアップが完了しました。

次の手順:
1. 新しいターミナルを開く（環境変数反映のため）
2. サービス起動:
   cd $PROJECT_ROOT
   docker compose -f docker/immich/docker-compose.yml up -d
   docker compose -f docker/jellyfin/docker-compose.yml up -d

3. 接続確認:
   - Immich: http://localhost:2283
   - Jellyfin: http://localhost:8096

4. VS Code設定:
   - Remote WSL拡張機能で接続
   - フォルダ: $PROJECT_ROOT

詳細は docs/setup/development-environment.md を参照してください。
EOF
            ;;
        "prod")
            cat << EOF
本番環境のベースセットアップが完了しました。

次の手順:
1. サービス設定確認・調整
2. Cloudflare Tunnel設定
3. セキュリティ設定の確認
4. バックアップ設定

詳細は docs/operations/README.md を参照してください。
EOF
            ;;
    esac
}

# スクリプト実行
main "$@"
