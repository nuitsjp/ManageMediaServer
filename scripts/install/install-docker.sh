#!/bin/bash
#
# WSL環境やLinuxサーバーにDockerをインストールするスクリプト
# Docker Desktopを使わずにネイティブインストールを行います
#

# スクリプトのディレクトリを取得
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"

# 共通ライブラリを読み込む
source "$SCRIPT_DIR/../lib/common.sh"

# スクリプトの説明
log_info "Docker インストールスクリプトを開始します"
log_info "このスクリプトは WSL 環境や Linux サーバーに Docker をインストールします"

# 管理者権限チェック
if [ "$(id -u)" -ne 0 ]; then
  log_error "このスクリプトは管理者権限で実行する必要があります"
  log_info "sudo $0 を実行してください"
  exit 1
fi

# Dockerがすでにインストールされているか確認
if command_exists docker && command_exists docker-compose; then
  log_success "Docker と Docker Compose がすでにインストールされています"
  log_info "Docker: $(docker --version)"
  log_info "Docker Compose: $(docker compose version)"
  
  # サービスの状態を確認
  if is_service_running docker; then
    log_success "Docker サービスは実行中です"
  else
    log_warning "Docker サービスが停止しています。開始します..."
    systemctl start docker
    systemctl enable docker
    wait_for_service docker
  fi
  
  # ユーザーがdockerグループに所属しているか確認
  if [ -n "$SUDO_USER" ] && getent group docker | grep -q "\b${SUDO_USER}\b"; then
    log_success "ユーザー $SUDO_USER は docker グループに所属しています"
  else
    log_warning "ユーザーが docker グループに所属していません。追加します..."
    if [ -n "$SUDO_USER" ]; then
      usermod -aG docker $SUDO_USER
      log_info "ユーザー $SUDO_USER を docker グループに追加しました"
      log_warning "グループ設定を反映するには、一度ログアウトするか、以下のコマンドを実行してください:"
      log_info "  newgrp docker"
    fi
  fi
  
  log_success "Dockerのセットアップは完了しています"
  log_info "スクリプトを終了します"
  exit 0
fi

# システムアップデート
log_info "システムパッケージを更新しています..."
apt update && apt upgrade -y

# 必要なパッケージの事前インストール
log_info "必要な依存パッケージをインストールしています..."
apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release

# Docker GPGキーの追加
log_info "Docker公式のGPGキーを追加しています..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Dockerリポジトリの追加
log_info "Dockerリポジトリを追加しています..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Docker Engineのインストール
log_info "Dockerパッケージのインストールを開始します..."
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Dockerサービスの起動と自動起動設定
log_info "Dockerサービスを起動して自動起動を設定しています..."
systemctl start docker
systemctl enable docker
wait_for_service docker 60

# Dockerグループの作成（既に存在していれば何もしない）
if ! getent group docker > /dev/null; then
  log_info "dockerグループを作成しています..."
  groupadd docker
fi

# 現在のユーザーをdockerグループに追加
if [ -n "$SUDO_USER" ]; then
  log_info "ユーザー $SUDO_USER をdockerグループに追加しています..."
  usermod -aG docker $SUDO_USER
  
  log_warning "グループ設定を反映するには、一度ログアウトするか、以下のコマンドを実行してください:"
  log_info "  newgrp docker"
else
  log_warning "sudoから実行されていないため、ユーザーをdockerグループに追加できません"
  log_info "手動で以下のコマンドを実行してください:"
  log_info "  sudo usermod -aG docker your_username"
fi

# Docker Composeのインストール確認
if command_exists docker-compose; then
  log_success "Docker Compose (スタンドアロン) がインストールされています: $(docker-compose --version)"
elif command -v docker compose > /dev/null; then
  log_success "Docker Compose Plugin がインストールされています: $(docker compose version)"
else
  log_warning "Docker Compose がインストールされていません、インストールします..."
  apt install -y docker-compose-plugin
  log_success "Docker Compose Plugin をインストールしました: $(docker compose version)"
fi

# Dockerのバージョン確認
log_success "Dockerのインストールが完了しました: $(docker --version)"

# 動作確認
log_info "Dockerの動作確認を行います..."
docker run --rm hello-world

log_success "Dockerが正常に動作しています"
log_info "次のステップ: Immich や Jellyfin のコンテナをセットアップします"

# 環境特有の設定
detect_and_configure_environment() {
  # WSL環境の検出
  if grep -q Microsoft /proc/version || grep -q WSL /proc/version; then
    log_info "WSL環境を検出しました。WSL固有の設定を適用します..."
    
    # WSL2のメモリ制限設定
    if [ ! -f /etc/wsl.conf ] || ! grep -q "\[wsl2\]" /etc/wsl.conf; then
      log_info "WSL設定ファイルを作成しています..."
      cat > /etc/wsl.conf << EOF
[wsl2]
memory=8GB
processors=4
swap=2GB
EOF
      log_info "WSL設定ファイルを作成しました。次回WSL起動時に適用されます。"
    else
      log_info "WSL設定ファイルは既に存在します。既存の設定を維持します。"
    fi
    
    # WSL用のDocker固有設定
    log_info "WSL用のDockerデーモン設定を適用します..."
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
      log_info "Dockerデーモン設定を作成しました。"
      systemctl restart docker
      wait_for_service docker
    fi
  else
    log_info "通常のLinux環境を検出しました。"
    
    # 通常のLinuxサーバー用の設定（必要に応じて）
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
      log_info "Dockerデーモン設定を作成しました。"
      systemctl restart docker
      wait_for_service docker
    fi
  fi
}

# 環境検出と設定適用
detect_and_configure_environment

log_success "Dockerの設定が完了しました"
exit 0
