#!/bin/bash
# WSL環境やLinuxサーバーにDockerとDocker Composeをインストールするスクリプト

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"

source "$SCRIPT_DIR/../lib/common.sh"

log_info "Docker インストールスクリプトを開始します"

# 管理者権限チェック
if [ "$(id -u)" -ne 0 ]; then
  log_error "このスクリプトは管理者権限で実行する必要があります"
  log_info "sudo $0 を実行してください"
  exit 1
fi

# 既存のDockerインストールを確認
if command_exists docker && command_exists docker-compose; then
  log_success "Docker と Docker Compose は既にインストール済み"
  log_info "Docker: $(docker --version)"
  log_info "Docker Compose: $(docker compose version)"
  
  # サービスの状態確認
  if is_service_running docker; then
    log_success "Docker サービス実行中"
  else
    log_warning "Docker サービスが停止しています。開始..."
    systemctl start docker
    systemctl enable docker
    wait_for_service docker
  fi
else
  log_info "Dockerをインストールします..."
  # システムパッケージの更新とインストール
  apt update && apt upgrade -y
  apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release

  # Docker GPGキーとリポジトリの追加
  log_info "Docker公式リポジトリを設定..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

  # Docker Engineのインストール
  log_info "Dockerパッケージのインストールを開始します..."
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # サービスの起動と自動起動設定
  log_info "Dockerサービスを起動して自動起動を設定しています..."
  systemctl start docker
  systemctl enable docker
  wait_for_service docker 60
fi

# dockerグループ作成とユーザー追加
if [ -n "$SUDO_USER" ]; then
  usermod -aG docker "$SUDO_USER"
  log_warning "再ログイン後または 'newgrp docker' で反映されます"
fi

# Docker Composeの確認とインストール
if command_exists docker-compose; then
  log_success "Docker Compose (スタンドアロン): $(docker-compose --version)"
elif command -v docker compose > /dev/null; then
  log_success "Docker Compose Plugin: $(docker compose version)"
else
  log_warning "Docker Compose をインストールします..."
  apt install -y docker-compose-plugin
  log_success "Docker Compose Plugin: $(docker compose version)"
fi

# インストール完了と動作確認
log_success "Dockerのインストール完了: $(docker --version)"
log_info "Dockerの動作確認..."
docker run --rm hello-world
log_success "Dockerが正常に動作しています"

# 環境特有の設定
detect_and_configure_environment() {
  if grep -q Microsoft /proc/version || grep -q WSL /proc/version; then
    log_info "WSL環境を検出、WSL固有の設定を適用..."
    
    # WSL2のリソース制限設定
    if [ ! -f /etc/wsl.conf ] || ! grep -q "\[wsl2\]" /etc/wsl.conf; then
      cat > /etc/wsl.conf << EOF
[wsl2]
memory=8GB
processors=4
swap=2GB
EOF
      log_info "WSL設定ファイルを作成しました"
    fi
    
    # WSL用のDockerデーモン設定
    if [ ! -f /etc/docker/daemon.json ] || ! grep -q "storage-driver" /etc/docker/daemon.json; then
      mkdir -p /etc/docker
      cat > /etc/docker/daemon.json << EOF
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF
      systemctl restart docker
      wait_for_service docker
    fi
  else
    # 通常のLinuxサーバー用の設定
    if [ ! -f /etc/docker/daemon.json ]; then
      mkdir -p /etc/docker
      cat > /etc/docker/daemon.json << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF
      systemctl restart docker
      wait_for_service docker
    fi
  fi
}

# 環境検出と設定適用
detect_and_configure_environment

log_success "Dockerの設定が完了しました"
exit 0
