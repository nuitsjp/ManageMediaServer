#!/bin/bash
# 開発環境（WSL）セットアップスクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/env-loader.sh" || log_error "env-loader.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗"

# 環境変数読み込み
load_environment

# WSL環境チェック
check_wsl_environment() {
    if ! is_wsl; then
        log_error "このスクリプトはWSL環境でのみ実行可能です"
    fi
    
    log_success "WSL環境を確認しました"
}

# システムパッケージ更新・インストール
install_system_packages() {
    log_info "=== システムパッケージ更新・インストール ==="
    
    # パッケージリスト更新
    log_info "パッケージリストを更新中..."
    sudo apt update
    
    # システム更新
    log_info "システムパッケージを更新中..."
    sudo apt upgrade -y
    
    # 基本パッケージインストール
    log_info "基本パッケージをインストール中..."
    sudo apt install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        git \
        htop \
        tree \
        jq \
        unzip \
        wget \
        apt-transport-https \
        software-properties-common \
        dos2unix \
        vim \
        nano
    
    log_success "システムパッケージのインストール完了"
}

# Docker CE インストール
install_docker() {
    log_info "=== Docker CE インストール ==="
    
    # 既存インストールチェック（新しい docker compose 形式に対応）
    if command_exists docker && docker compose version >/dev/null 2>&1; then
        log_info "Dockerは既にインストール済みです"
        docker --version
        docker compose version
        return 0
    fi
    
    # 古いDockerパッケージ削除
    log_info "古いDockerパッケージを削除中..."
    sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # DockerのGPGキー追加
    log_info "DockerのGPGキーを追加中..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Dockerリポジトリ追加
    log_info "Dockerリポジトリを追加中..."
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # パッケージリスト更新
    sudo apt update
    
    # Docker CE インストール
    log_info "Docker CE をインストール中..."
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # ユーザーをdockerグループに追加
    log_info "ユーザーをdockerグループに追加中..."
    sudo usermod -aG docker "$USER"
    
    # Docker Compose Standalone インストール（オプション）
    if [ "${INSTALL_DOCKER_COMPOSE_STANDALONE:-false}" = "true" ]; then
        log_info "Docker Compose Standalone をインストール中..."
        local compose_version="v2.21.0"
        sudo curl -L "https://github.com/docker/compose/releases/download/$compose_version/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
    
    # Docker サービス起動・有効化
    log_info "Dockerサービスを起動・有効化中..."
    sudo systemctl start docker
    sudo systemctl enable docker
    
    log_success "Docker CE のインストール完了"
    log_warning "Dockerグループの変更を反映するため、一度ログアウト・ログインしてください"
}

# rclone インストール
install_rclone() {
    log_info "=== rclone インストール ==="
    
    # 既存インストールチェック
    if command_exists rclone; then
        log_info "rcloneは既にインストール済みです"
        rclone version
        return 0
    fi
    
    # rclone インストール
    log_info "rclone をインストール中..."
    curl https://rclone.org/install.sh | sudo bash
    
    # 設定ディレクトリ作成
    ensure_dir_exists "$(dirname "$RCLONE_CONFIG_PATH")"
    ensure_dir_exists "$RCLONE_LOG_PATH"
    
    # テスト用設定ファイル作成（実際のクラウド設定は手動）
    if [ ! -f "$RCLONE_CONFIG_PATH" ]; then
        cat > "$RCLONE_CONFIG_PATH" << EOF
# rclone設定ファイル（開発環境用）
# 実際のクラウドストレージ設定は 'rclone config' で設定してください
#
# 設定例:
# [gdrive]
# type = drive
# scope = drive.readonly
# ...

[local-test]
type = local
# 開発・テスト用のローカルストレージ設定
EOF
        log_info "テスト用rclone設定ファイルを作成しました: $RCLONE_CONFIG_PATH"
        log_warning "実際のクラウドストレージとの連携は 'rclone config' で設定してください"
    fi
    
    log_success "rclone のインストール完了"
}

# Docker Compose設定準備
prepare_docker_compose() {
    log_info "=== Docker Compose設定準備 ==="
    
    # 新しい構造では各サービスのディレクトリが既に存在している前提
    # .envファイルの生成は auto-setup.sh で実行済み
    
    local immich_dir="$PROJECT_ROOT/docker/immich"
    local jellyfin_dir="$PROJECT_ROOT/docker/jellyfin"
    
    if [ ! -d "$immich_dir" ] || [ ! -d "$jellyfin_dir" ]; then
        log_error "Docker設定ディレクトリが見つかりません"
        log_error "Immich: $immich_dir"
        log_error "Jellyfin: $jellyfin_dir"
        log_error "プロジェクトの統合構造を確認してください"
        return 1
    fi
    
    # .envファイルの存在確認
    if [ ! -f "$immich_dir/.env" ]; then
        log_error "Immich .envファイルが見つかりません: $immich_dir/.env"
        log_info "auto-setup.sh を先に実行してください"
        return 1
    fi
    
    if [ ! -f "$jellyfin_dir/.env" ]; then
        log_error "Jellyfin .envファイルが見つかりません: $jellyfin_dir/.env"
        log_info "auto-setup.sh を先に実行してください"
        return 1
    fi
    
    log_success "Docker Compose設定準備完了"
}

# 開発用便利スクリプト作成
create_dev_scripts() {
    log_info "=== 開発用便利スクリプト作成 ==="
    
    local dev_scripts_dir="$PROJECT_ROOT/scripts/dev"
    ensure_dir_exists "$dev_scripts_dir"
    
    # サービス起動スクリプト
    cat > "$dev_scripts_dir/start-services.sh" << 'EOF'
#!/bin/bash
# 開発サービス一括起動
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/env-loader.sh"

log_info "=== 開発サービス起動 ==="

cd "$PROJECT_ROOT"

# Immichサービス起動
log_info "Immichを起動中..."
docker compose -f docker/immich/docker-compose.yml up -d

# Jellyfinサービス起動
log_info "Jellyfinを起動中..."
docker compose -f docker/jellyfin/docker-compose.yml up -d

log_success "サービス起動完了"
log_info "Immich: http://localhost:2283"
log_info "Jellyfin: http://localhost:8096"
EOF
    chmod +x "$dev_scripts_dir/start-services.sh"
    
    # サービス停止スクリプト
    cat > "$dev_scripts_dir/stop-services.sh" << 'EOF'
#!/bin/bash
# 開発サービス一括停止
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/common.sh"

log_info "=== 開発サービス停止 ==="

cd "$PROJECT_ROOT"

# Jellyfinサービス停止
log_info "Jellyfinを停止中..."
docker compose -f docker/jellyfin/docker-compose.yml down

# Immichサービス停止
log_info "Immichを停止中..."
docker compose -f docker/immich/docker-compose.yml down

log_success "サービス停止完了"
EOF
    chmod +x "$dev_scripts_dir/stop-services.sh"
    
    # 開発データリセットスクリプト
    cat > "$dev_scripts_dir/reset-dev-data.sh" << 'EOF'
#!/bin/bash
# 開発データリセット
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/env-loader.sh"

log_warning "開発データをリセットします"
log_warning "この操作により以下のデータが削除されます:"
log_warning "- Immichライブラリ ($DATA_ROOT/immich)"
log_warning "- Jellyfinライブラリ ($DATA_ROOT/jellyfin)"
log_warning "- 一時ファイル ($DATA_ROOT/temp)"

if ! confirm_action "本当にリセットしますか？"; then
    log_info "リセットをキャンセルしました"
    exit 0
fi

# サービス停止
log_info "サービスを停止中..."
"$SCRIPT_DIR/stop-services.sh"

# データディレクトリ削除・再作成
log_info "データディレクトリをリセット中..."
rm -rf "$DATA_ROOT/immich/library" "$DATA_ROOT/immich/postgres" "$DATA_ROOT/immich/model-cache"
rm -rf "$DATA_ROOT/jellyfin" "$DATA_ROOT/temp"/*

# ディレクトリ再作成
mkdir -p "$DATA_ROOT/immich/library" "$DATA_ROOT/immich/external"
mkdir -p "$DATA_ROOT/jellyfin/config" "$DATA_ROOT/jellyfin/movies"
mkdir -p "$DATA_ROOT/temp"

log_success "開発データのリセット完了"
log_info "サービス再起動: $SCRIPT_DIR/start-services.sh"
EOF
    chmod +x "$dev_scripts_dir/reset-dev-data.sh"
    
    log_success "開発用便利スクリプトを作成しました"
}

# 権限設定
setup_permissions() {
    log_info "=== 権限設定 ==="
    
    # 改行コード変換（Windows側で作成されたファイル対応）
    log_info "改行コードを変換中..."
    find "$PROJECT_ROOT" -name "*.sh" -o -name "*.env" -o -name "*.yml" -o -name "*.yaml" | xargs dos2unix 2>/dev/null || true
    
    # データディレクトリ権限設定
    chmod -R 755 "$DATA_ROOT"
    chmod -R 750 "$DATA_ROOT/config"
    
    # バックアップディレクトリ権限設定  
    chmod -R 755 "$BACKUP_ROOT"
    
    # 実行ファイル権限設定
    find "$PROJECT_ROOT/scripts" -name "*.sh" -exec chmod +x {} \;
    
    log_success "権限設定完了"
}

# 動作確認
verify_installation() {
    log_info "=== 動作確認 ==="
    
    # Docker動作確認
    if command_exists docker; then
        log_info "Docker バージョン: $(docker --version)"
        if docker info >/dev/null 2>&1; then
            log_success "Docker は正常に動作しています"
        else
            log_warning "Docker デーモンが起動していません（Dockerグループ変更後の再ログインが必要な可能性があります）"
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
    
    # ディレクトリ確認
    local dirs=("$DATA_ROOT" "$BACKUP_ROOT" "$DATA_ROOT/immich" "$DATA_ROOT/jellyfin")
    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ]; then
            log_success "ディレクトリ確認: $dir"
        else
            log_error "ディレクトリが作成されていません: $dir"
        fi
    done
    
    log_success "動作確認完了"
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
    
    log_info "=== 開発環境（WSL）セットアップ開始 ==="
    
    # WSL環境チェック
    check_wsl_environment
    
    # セットアップ処理実行
    install_system_packages
    install_docker
    install_rclone
    prepare_docker_compose
    create_dev_scripts
    setup_permissions
    
    # 動作確認
    verify_installation
    
    log_success "=== 開発環境セットアップ完了 ==="
    
    # 次のステップ案内
    cat << EOF

次のステップ:
1. 新しいターミナルを開く（Dockerグループ変更反映のため）
2. サービス起動:
   cd $PROJECT_ROOT
   ./scripts/dev/start-services.sh

3. 接続確認:
   - Immich: http://localhost:2283
   - Jellyfin: http://localhost:8096

4. クラウドストレージ設定（必要に応じて）:
   rclone config

開発用コマンド:
- サービス起動: ./scripts/dev/start-services.sh  
- サービス停止: ./scripts/dev/stop-services.sh
- データリセット: ./scripts/dev/reset-dev-data.sh
EOF
}

# スクリプト実行
main "$@"
