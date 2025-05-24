#!/bin/bash
set -euo pipefail
#
# WSL環境やLinuxサーバーにDockerとDocker Composeをインストールするスクリプト
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 共通ライブラリ読み込み ---
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗しました。" >&2; exit 1; }
# shellcheck source=../lib/config.sh
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗しました。"

# --- 事前チェック ---
pre_check() {
    # 管理者権限チェック
    if [ "$(id -u)" -ne 0 ]; then
        log_error "このスクリプトは管理者権限で実行する必要があります"
        log_info "sudo $0 を実行してください"
        exit 1
    fi
    
    # OS確認
    if ! grep -qE "(Ubuntu|Debian)" /etc/os-release; then
        log_warning "このスクリプトはUbuntu/Debian向けです。他のディストリビューションでは動作しない可能性があります"
    fi
}

# --- インストール済みチェック ---
is_already_installed() {
    if command_exists docker && (command_exists docker-compose || docker compose version >/dev/null 2>&1); then
        return 0
    fi
    return 1
}

# --- バージョン情報表示 ---
show_version_info() {
    log_info "Docker: $(docker --version 2>/dev/null || echo "未インストール")"
    if command_exists docker-compose; then
        log_info "Docker Compose (standalone): $(docker-compose --version)"
    elif docker compose version >/dev/null 2>&1; then
        log_info "Docker Compose (plugin): $(docker compose version)"
    fi
}

# --- Dockerインストール ---
install_docker() {
    log_info "システムパッケージを更新中..."
    apt-get update -qq
    apt-get upgrade -y -qq
    
    log_info "必要なパッケージをインストール中..."
    apt-get install -y -qq \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common \
        gnupg \
        lsb-release
    
    log_info "Docker GPGキーを追加中..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor --yes -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    log_info "Dockerリポジトリを設定中..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    log_info "Dockerパッケージをインストール中..."
    apt-get update -qq
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin
    
    # Docker Composeスタンドアロン版も必要な場合はインストール
    if [ "${INSTALL_DOCKER_COMPOSE_STANDALONE:-false}" = "true" ]; then
        log_info "Docker Compose スタンドアロン版をインストール中..."
        apt-get install -y -qq docker-compose
    fi
}

# --- Dockerサービス設定 ---
configure_docker_service() {
    log_info "Dockerサービスを起動中..."
    systemctl start docker
    systemctl enable docker
    
    # サービス起動待機
    wait_for_service docker 60
    
    # 実行ユーザーをdockerグループに追加
    if [ -n "${SUDO_USER:-}" ]; then
        log_info "ユーザー '$SUDO_USER' をdockerグループに追加中..."
        usermod -aG docker "$SUDO_USER"
        log_warning "変更を反映するには再ログインするか 'newgrp docker' を実行してください"
    fi
}

# --- 環境別設定 ---
configure_environment() {
    local daemon_config="/etc/docker/daemon.json"
    local wsl_detected=false
    
    # WSL環境検出
    if grep -qE "(Microsoft|WSL)" /proc/version 2>/dev/null; then
        wsl_detected=true
        log_info "WSL環境を検出しました"
    fi
    
    # Docker daemon設定
    log_info "Docker daemon設定を適用中..."
    mkdir -p /etc/docker
    
    if [ "$wsl_detected" = true ]; then
        # WSL用設定
        cat > "$daemon_config" <<EOF
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF
        
        # WSLリソース制限設定（ユーザーホームに作成）
        if [ -n "${SUDO_USER:-}" ] && [ -d "/home/${SUDO_USER}" ]; then
            local wsl_config="/home/${SUDO_USER}/.wslconfig"
            if [ ! -f "$wsl_config" ]; then
                cat > "$wsl_config" <<EOF
[wsl2]
memory=8GB
processors=4
swap=2GB
EOF
                chown "${SUDO_USER}:${SUDO_USER}" "$wsl_config"
                log_info "WSL設定ファイルを作成しました: $wsl_config"
                log_warning "設定を反映するにはWSLの再起動が必要です"
            fi
        fi
    else
        # 通常のLinux環境用設定
        cat > "$daemon_config" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF
    fi
    
    # 設定適用のためDockerを再起動
    systemctl restart docker
    wait_for_service docker 30
}

# --- インストール確認 ---
verify_installation() {
    log_info "Dockerの動作確認中..."
    
    # hello-worldコンテナ実行
    if docker run --rm hello-world >/dev/null 2>&1; then
        log_success "Dockerは正常に動作しています"
    else
        log_error "Docker動作確認に失敗しました"
        return 1
    fi
    
    # Docker Compose確認
    if docker compose version >/dev/null 2>&1; then
        log_success "Docker Compose Pluginは正常に動作しています"
    elif command_exists docker-compose; then
        log_success "Docker Compose (standalone)は正常に動作しています"
    else
        log_warning "Docker Composeが見つかりません"
    fi
}

# --- メイン処理 ---
main() {
    log_info "=== Docker インストール開始 ==="
    
    # 事前チェック
    pre_check
    
    # 冪等性チェック
    if is_already_installed; then
        log_success "Docker と Docker Compose は既にインストール済みです"
        show_version_info
        return 0
    fi
    
    # インストール実行
    install_docker
    
    # サービス設定
    configure_docker_service
    
    # 環境別設定
    configure_environment
    
    # 動作確認
    verify_installation
    
    # 完了メッセージ
    show_version_info
    log_success "=== Docker インストール完了 ==="
}

# エントリーポイント
main "$@"