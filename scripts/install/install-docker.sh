#!/bin/bash
#
# WSL環境にDockerをインストールするスクリプト
# Docker Desktopを使わずにネイティブインストールを行います
#

set -e

# 色の設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# ログ関数
log() {
  local level=$1
  local message=$2
  local color=$NC
  
  case $level in
    "INFO") color=$NC ;;
    "SUCCESS") color=$GREEN ;;
    "WARN") color=$YELLOW ;;
    "ERROR") color=$RED ;;
  esac
  
  echo -e "[$(date '+%H:%M:%S')] ${color}${message}${NC}"
}

# エラーハンドリング
handle_error() {
  log "ERROR" "エラーが発生しました: $1"
  exit 1
}

trap 'handle_error "$BASH_COMMAND"' ERR

# 管理者権限チェック
if [ "$(id -u)" -ne 0 ]; then
  log "ERROR" "このスクリプトは管理者権限で実行する必要があります"
  log "INFO" "sudo ./install-docker.sh を実行してください"
  exit 1
fi

# システムアップデート
log "INFO" "システムパッケージを更新しています..."
apt update && apt upgrade -y

# 必要なパッケージの事前インストール
log "INFO" "必要な依存パッケージをインストールしています..."
apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release

# Docker GPGキーの追加
log "INFO" "Docker公式のGPGキーを追加しています..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Dockerリポジトリの追加
log "INFO" "Dockerリポジトリを追加しています..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Docker Engineのインストール
log "INFO" "Dockerパッケージのインストールを開始します..."
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Dockerサービスの起動と自動起動設定
log "INFO" "Dockerサービスを起動して自動起動を設定しています..."
systemctl start docker
systemctl enable docker

# Dockerグループの作成（既に存在していれば何もしない）
if ! getent group docker > /dev/null; then
  log "INFO" "dockerグループを作成しています..."
  groupadd docker
fi

# 現在のユーザーをdockerグループに追加
if [ -n "$SUDO_USER" ]; then
  log "INFO" "ユーザー $SUDO_USER をdockerグループに追加しています..."
  usermod -aG docker $SUDO_USER
  
  log "WARN" "グループ設定を反映するには、一度ログアウトするか、以下のコマンドを実行してください:"
  log "INFO" "  newgrp docker"
else
  log "WARN" "sudoから実行されていないため、ユーザーをdockerグループに追加できません"
  log "INFO" "手動で以下のコマンドを実行してください:"
  log "INFO" "  sudo usermod -aG docker your_username"
fi

# Docker Composeのインストール確認
if command -v docker compose > /dev/null; then
  log "SUCCESS" "Docker Compose Plugin がインストールされています: $(docker compose version)"
else
  log "WARN" "Docker Compose Plugin がインストールされていません"
  log "INFO" "手動でインストールするには: sudo apt install -y docker-compose-plugin"
fi

# Dockerのバージョン確認
log "SUCCESS" "Dockerのインストールが完了しました: $(docker --version)"

# 動作確認
log "INFO" "Dockerの動作確認を行います..."
docker run --rm hello-world

log "SUCCESS" "Dockerが正常に動作しています"
log "INFO" "次のステップ: Immich や Jellyfin のコンテナをセットアップします"

# WSL固有の設定
if grep -q Microsoft /proc/version; then
  log "INFO" "WSL環境を検出しました。WSL固有の設定を適用します..."
  
  # WSL2のメモリ制限設定（オプション）
  if [ ! -f /etc/wsl.conf ]; then
    log "INFO" "WSL設定ファイルを作成しています..."
    cat > /etc/wsl.conf << EOF
[wsl2]
memory=8GB
processors=4
swap=2GB
EOF
    log "INFO" "WSL設定ファイルを作成しました。次回WSL起動時に適用されます。"
  fi
fi

exit 0
