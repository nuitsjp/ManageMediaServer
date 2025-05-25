#!/bin/bash
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
        "$DATA_ROOT/immich"
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
}

# 設定ファイル展開
deploy_config_files() {
    log_info "=== 設定ファイル展開 ==="
    
    # Immich .envファイル生成
    generate_immich_env
    
    # Jellyfin .envファイル生成
    generate_jellyfin_env
    
    # シェル環境に環境変数設定を追加
    setup_shell_environment
    
    log_success "設定ファイル展開完了"
}

# Immich用.envファイル生成
generate_immich_env() {
    local immich_env_file="$PROJECT_ROOT/docker/immich/.env"
    local immich_example_file="$PROJECT_ROOT/docker/immich/.env.example"
    
    if [ ! -f "$immich_env_file" ] || [ "${FORCE:-false}" = "true" ]; then
        if [ -f "$immich_example_file" ]; then
            # .env.exampleをベースにして環境固有の値を設定
            cp "$immich_example_file" "$immich_env_file"
            
            # 環境固有の値を設定
            sed -i "s|UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${IMMICH_DIR_PATH}/library|" "$immich_env_file"
            sed -i "s|DB_DATA_LOCATION=.*|DB_DATA_LOCATION=${IMMICH_DIR_PATH}/postgres|" "$immich_env_file"
            sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${IMMICH_DB_PASSWORD:-postgres}|" "$immich_env_file"
            
            # 外部ライブラリパスのコメントアウトを解除（必要に応じて）
            if [ -n "${IMMICH_EXTERNAL_PATH:-}" ]; then
                sed -i "s|# EXTERNAL_PATH=.*|EXTERNAL_PATH=${IMMICH_EXTERNAL_PATH}|" "$immich_env_file"
            fi
            
            log_success "Immich .envファイルを生成しました: $immich_env_file"
        else
            log_error "Immich .env.exampleファイルが見つかりません: $immich_example_file"
        fi
    else
        log_info "Immich .envは既に存在します（--force で強制上書き可能）"
    fi
}

# Jellyfin用.envファイル生成
generate_jellyfin_env() {
    local jellyfin_env_file="$PROJECT_ROOT/docker/jellyfin/.env"
    local jellyfin_example_file="$PROJECT_ROOT/docker/jellyfin/.env.example"
    
    if [ ! -f "$jellyfin_env_file" ] || [ "${FORCE:-false}" = "true" ]; then
        if [ -f "$jellyfin_example_file" ]; then
            # .env.exampleをベースにして環境固有の値を設定
            cp "$jellyfin_example_file" "$jellyfin_env_file"
            
            # 環境固有の値を設定
            sed -i "s|JELLYFIN_CONFIG_PATH=.*|JELLYFIN_CONFIG_PATH=${JELLYFIN_CONFIG_PATH}|" "$jellyfin_env_file"
            sed -i "s|JELLYFIN_MEDIA_PATH=.*|JELLYFIN_MEDIA_PATH=${JELLYFIN_MEDIA_PATH}|" "$jellyfin_env_file"
            sed -i "s|JELLYFIN_CACHE_PATH=.*|JELLYFIN_CACHE_PATH=${DATA_ROOT}/jellyfin/cache|" "$jellyfin_env_file"
            sed -i "s|JELLYFIN_TEMP_PATH=.*|JELLYFIN_TEMP_PATH=${DATA_ROOT}/temp|" "$jellyfin_env_file"
            
            log_success "Jellyfin .envファイルを生成しました: $jellyfin_env_file"
        else
            log_error "Jellyfin .env.exampleファイルが見つかりません: $jellyfin_example_file"
        fi
    else
        log_info "Jellyfin .envは既に存在します（--force で強制上書き可能）"
    fi
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
    log_info "=== Docker CEのインストール ==="
    
    # 既存のDockerがインストールされている場合はアンインストール
    if command_exists "docker"; then
        apt remove -y docker docker-engine docker.io containerd runc || true
    fi
    
    # Dockerの公式GPGキーを追加
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    
    # Dockerリポジトリを追加
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    
    # パッケージリスト更新
    apt update -y
    
    # Docker CEインストール
    apt install -y docker-ce docker-ce-cli containerd.io
    
    # Dockerグループにユーザーを追加
    usermod -aG docker $USER
    
    log_success "Docker CEのインストールが完了しました"
}

# rcloneインストール
install_rclone() {
    log_info "=== rcloneのインストール ==="
    
    # rcloneの公式GPGキーを追加
    curl https://rclone.org/install.sh | sudo bash
    
    log_success "rcloneのインストールが完了しました"
}

# 開発用スクリプト生成
create_dev_scripts() {
    log_info "=== 開発用スクリプトの生成 ==="
    
    local scripts_dir="$PROJECT_ROOT/scripts"
    
    # スクリプトディレクトリが存在しない場合は作成
    ensure_dir_exists "$scripts_dir"
    
    # start-services.sh の生成
    cat > "$scripts_dir/start-services.sh" << 'EOF'
#!/bin/bash
# サービス起動スクリプト

# 環境変数読み込み
source "$(dirname "$0")/../lib/common.sh"

# Immich サービス起動
docker compose -f "$PROJECT_ROOT/docker/dev/docker-compose.yml" up -d

# Jellyfin サービス起動
docker compose -f "$PROJECT_ROOT/docker/jellyfin/docker-compose.yml" up -d

echo "サービスが起動しました。"
EOF
    
    # stop-services.sh の生成
    cat > "$scripts_dir/stop-services.sh" << 'EOF'
#!/bin/bash
# サービス停止スクリプト

# 環境変数読み込み
source "$(dirname "$0")/../lib/common.sh"

# Immich サービス停止
docker compose -f "$PROJECT_ROOT/docker/dev/docker-compose.yml" down

# Jellyfin サービス停止
docker compose -f "$PROJECT_ROOT/docker/jellyfin/docker-compose.yml" down

echo "サービスが停止しました。"
EOF
    
    # reset-dev-data.sh の生成
    cat > "$scripts_dir/reset-dev-data.sh" << 'EOF'
#!/bin/bash
# 開発データリセットスクリプト

# 環境変数読み込み
source "$(dirname "$0")/../lib/common.sh"

# データのバックアップ
rclone copy "$DATA_ROOT" "remote:backup/media-$(date +%Y%m%d%H%M%S)" --progress

# データのリセット
rm -rf "$DATA_ROOT/immich/library/*"
rm -rf "$DATA_ROOT/jellyfin/movies/*"

echo "開発データがリセットされました。"
EOF
    
    # 実行権限を付与
    chmod +x "$scripts_dir/"*.sh
    
    log_success "開発用スクリプトの生成が完了しました"
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
    
    # 環境情報表示
    show_environment_info "$env_type"
    
    if [ "$dry_run" = "true" ]; then
        log_info "=== ドライラン: 以下の処理が実行されます ==="
        echo "1. 事前チェック"
        echo "2. ディレクトリ準備"
        echo "3. 設定ファイル展開"
        echo "4. 環境別セットアップスクリプト実行"
        echo "   - 環境: $env_type"
        echo "   - スクリプト: $SCRIPT_DIR/setup-$env_type.sh"
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
    if [ "$env_type" = "prod" ]; then
        log_info "=== 本番環境セットアップ ==="
        bash "$SCRIPT_DIR/setup-prod.sh" $script_args
    else
        log_info "=== 開発環境セットアップ ==="
        create_dev_scripts
        # 必要ならsystemd関連セットアップ処理もここで呼び出し
    fi

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
   docker compose -f docker/dev/docker-compose.yml up -d

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
