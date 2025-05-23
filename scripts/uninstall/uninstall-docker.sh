#!/bin/bash
#
# WSL環境やLinuxサーバーからDockerをアンインストールするスクリプト
#

# スクリプトのディレクトリを取得
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"

# 共通ライブラリを読み込む
source "$SCRIPT_DIR/../lib/common.sh"

# 強制モードの確認
FORCE=false
if [[ "$1" == "--force" ]]; then
    FORCE=true
    log_warning "強制モードが有効です。確認プロンプトなしで処理を実行します。"
fi

# スクリプトの説明
log_info "Docker アンインストールスクリプトを開始します"
log_info "このスクリプトは WSL 環境や Linux サーバーから Docker を削除します"

# 管理者権限チェック
if [ "$(id -u)" -ne 0 ]; then
    log_error "このスクリプトは管理者権限で実行する必要があります"
    log_info "sudo $0 を実行してください"
    exit 1
fi

# Dockerが実行中か確認
if is_service_running docker; then
    log_warning "Dockerサービスが実行中です"
    
    # 実行中のコンテナがあるか確認
    if command_exists docker && [ "$(docker ps -q 2>/dev/null | wc -l)" -gt 0 ]; then
        log_warning "実行中のDockerコンテナがあります"
        docker ps
        
        if [[ "$FORCE" != "true" ]]; then
            if ! confirm "実行中のコンテナを停止してよろしいですか？" "n"; then
                log_info "アンインストールを中止しました"
                exit 0
            fi
        fi
        
        log_info "すべてのコンテナを停止しています..."
        docker stop $(docker ps -q) 2>/dev/null || true
    fi
    
    # Dockerイメージがあるか確認
    if command_exists docker && [ "$(docker images -q 2>/dev/null | wc -l)" -gt 0 ]; then
        log_warning "Dockerイメージが存在します"
        
        if [[ "$FORCE" != "true" ]]; then
            if ! confirm "すべてのDockerイメージを削除してよろしいですか？" "n"; then
                log_info "イメージを残したままアンインストールします"
            else
                log_info "すべてのDockerイメージを削除しています..."
                docker rmi -f $(docker images -q) 2>/dev/null || true
            fi
        else
            log_info "すべてのDockerイメージを削除しています..."
            docker rmi -f $(docker images -q) 2>/dev/null || true
        fi
    fi
    
    # Dockerボリュームがあるか確認
    if command_exists docker && [ "$(docker volume ls -q 2>/dev/null | wc -l)" -gt 0 ]; then
        log_warning "Dockerボリュームが存在します"
        
        if [[ "$FORCE" != "true" ]]; then
            if ! confirm "すべてのDockerボリュームを削除してよろしいですか？ これによりデータが失われる可能性があります" "n"; then
                log_info "ボリュームを残したままアンインストールします"
            else
                log_info "すべてのDockerボリュームを削除しています..."
                docker volume rm $(docker volume ls -q) 2>/dev/null || true
            fi
        else
            log_info "すべてのDockerボリュームを削除しています..."
            docker volume rm $(docker volume ls -q) 2>/dev/null || true
        fi
    fi
    
    # Dockerネットワークの削除（デフォルトネットワーク以外）
    if command_exists docker; then
        log_info "カスタムDockerネットワークを削除しています..."
        docker network ls --filter "type=custom" -q | xargs -r docker network rm 2>/dev/null || true
    fi
    
    log_info "Dockerサービスを停止しています..."
    systemctl stop docker 2>/dev/null || true
    systemctl disable docker 2>/dev/null || true
fi

# アンインストール確認
if [[ "$FORCE" != "true" ]]; then
    if ! confirm "Dockerをアンインストールしてよろしいですか？" "n"; then
        log_info "アンインストールを中止しました"
        exit 0
    fi
fi

# Dockerの設定ファイル・データディレクトリのバックアップ
if [[ -d "/etc/docker" || -d "/var/lib/docker" ]]; then
    log_info "Docker設定の保存先をチェックしています..."
    
    if [[ "$FORCE" != "true" ]]; then
        if confirm "Docker設定ファイルとデータディレクトリをバックアップしますか？" "y"; then
            BACKUP_DIR="/tmp/docker-backup-$(date +%Y%m%d%H%M%S)"
            log_info "バックアップを作成しています: $BACKUP_DIR"
            mkdir -p "$BACKUP_DIR"
            
            if [[ -d "/etc/docker" ]]; then
                cp -r /etc/docker "$BACKUP_DIR/" 2>/dev/null || true
            fi
            
            # /var/lib/dockerは巨大な可能性があるため、設定ファイルのみバックアップ
            if [[ -f "/var/lib/docker/daemon.json" ]]; then
                mkdir -p "$BACKUP_DIR/var-lib-docker"
                cp /var/lib/docker/daemon.json "$BACKUP_DIR/var-lib-docker/" 2>/dev/null || true
            fi
            
            log_success "バックアップを作成しました: $BACKUP_DIR"
        fi
    fi
fi

# Docker関連パッケージの検出とアンインストール
log_info "Dockerパッケージをアンインストールしています..."

# 環境検出（Ubuntu/Debian系）
if command_exists apt-get; then
    DOCKER_PACKAGES=(
        "docker-ce"
        "docker-ce-cli"
        "containerd.io"
        "docker-compose-plugin"
        "docker-buildx-plugin"
        "docker.io"
        "docker-compose"
    )
    
    for pkg in "${DOCKER_PACKAGES[@]}"; do
        if dpkg -l | grep -q "$pkg"; then
            log_info "パッケージを削除: $pkg"
            apt-get remove --purge -y "$pkg" || true
        fi
    done
    
    # 依存関係の削除
    log_info "未使用の依存関係を削除しています..."
    apt-get autoremove -y
    apt-get autoclean
fi

# Docker関連ディレクトリとファイルの削除
log_info "Docker関連ファイルとディレクトリを削除しています..."

DOCKER_DIRS=(
    "/etc/docker"
    "/var/lib/docker"
    "/var/lib/containerd"
    "/var/run/docker"
    "/var/run/docker.sock"
    "/usr/local/bin/docker-compose"
)

for dir in "${DOCKER_DIRS[@]}"; do
    if [[ -e "$dir" ]]; then
        log_info "削除: $dir"
        rm -rf "$dir" 2>/dev/null || true
    fi
done

# Dockerリポジトリの削除
if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
    log_info "Dockerリポジトリを削除しています..."
    rm -f /etc/apt/sources.list.d/docker.list
fi

# GPGキーの削除
if [[ -f /usr/share/keyrings/docker-archive-keyring.gpg ]]; then
    log_info "DockerのGPGキーを削除しています..."
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg
fi

# ユーザーをdockerグループから削除（オプション）
if [[ "$FORCE" != "true" ]]; then
    if [[ -n "$SUDO_USER" ]] && getent group docker | grep -q "\b${SUDO_USER}\b"; then
        if confirm "ユーザー $SUDO_USER をdockerグループから削除しますか？" "y"; then
            log_info "ユーザー $SUDO_USER をdockerグループから削除しています..."
            gpasswd -d "$SUDO_USER" docker 2>/dev/null || true
        fi
    fi
else
    if [[ -n "$SUDO_USER" ]] && getent group docker | grep -q "\b${SUDO_USER}\b"; then
        log_info "ユーザー $SUDO_USER をdockerグループから削除しています..."
        gpasswd -d "$SUDO_USER" docker 2>/dev/null || true
    fi
fi

# dockerグループの削除（オプション）
if getent group docker > /dev/null; then
    if [[ "$FORCE" == "true" ]] || confirm "dockerグループを削除しますか？" "y"; then
        log_info "dockerグループを削除しています..."
        groupdel docker 2>/dev/null || true
    fi
fi

# WSL特有の設定を削除
if grep -q Microsoft /proc/version || grep -q WSL /proc/version; then
    log_info "WSL環境を検出しました。WSL固有の設定を削除します..."
    
    # WSL設定ファイルからDocker関連の設定を削除
    if [[ -f /etc/wsl.conf ]] && grep -q "\[wsl2\]" /etc/wsl.conf; then
        log_info "WSL設定ファイルからDocker関連の設定を削除しています..."
        
        # wsl.confファイルのバックアップを作成
        backup_file "/etc/wsl.conf"
        
        # Dockerに関する設定のみを削除し、他の設定は保持
        TMP_FILE=$(mktemp)
        grep -v -E "memory=|processors=|swap=" /etc/wsl.conf > "$TMP_FILE"
        mv "$TMP_FILE" /etc/wsl.conf
    fi
fi

# aptパッケージリストを更新
if command_exists apt-get; then
    log_info "パッケージリストを更新しています..."
    apt-get update
fi

log_success "Dockerのアンインストールが完了しました"
log_warning "システムを完全にクリーンアップするには、再起動することをお勧めします"
log_info "再起動するには次のコマンドを実行してください: 'sudo reboot'"

exit 0
