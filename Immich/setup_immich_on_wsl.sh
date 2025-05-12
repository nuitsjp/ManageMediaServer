#!/bin/bash
# setup_immich_on_wsl.sh

# エラーが発生したらスクリプトを終了する
set -e

# --- パラメータ ---
# PowerShellスクリプトから引数として渡される
TIME_ZONE="$1"
IMMICH_DIR_PARAM="$2"
# DISTRO_CODENAME は lsb_release -cs で取得するため、ここでは不要になりました。

# --- ヘルパー関数 ---
log() {
    echo "[WSL_SCRIPT INFO] $1"
}

warn() {
    echo "[WSL_SCRIPT WARN] $1" >&2
}

error_exit() {
    echo "[WSL_SCRIPT ERROR] $1" >&2
    exit 1
}

# --- パラメータ検証 ---
if [ -z "$TIME_ZONE" ]; then
    error_exit "TimeZone パラメータが設定されていません。"
fi
if [ -z "$IMMICH_DIR_PARAM" ]; then
    error_exit "ImmichDir パラメータが設定されていません。"
fi

# IMMICH_DIR_PARAM の解決 (~/ を展開)
# スクリプト実行ユーザーのホームディレクトリ基準で展開
if [[ "$IMMICH_DIR_PARAM" == "~/"* ]]; then
    # $HOME はスクリプト実行ユーザーのホームディレクトリ
    IMMICH_DIR="$HOME/${IMMICH_DIR_PARAM#\~/}"
else
    IMMICH_DIR="$IMMICH_DIR_PARAM"
fi

log "パッケージリストの更新と既存パッケージのアップグレード..."
sudo apt update && sudo apt upgrade -y

log "Dockerインストール用の前提パッケージをインストール..."
sudo apt install -y ca-certificates curl gnupg lsb-release

log "DockerのGPGキーとリポジトリを設定..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

DISTRO_CODENAME=$(lsb_release -cs)
if [ -z "$DISTRO_CODENAME" ]; then
    error_exit "ディストリビューションのコードネームを取得できませんでした。"
fi
log "ディストリビューション コードネーム: $DISTRO_CODENAME"

REPO_LINE="deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $DISTRO_CODENAME stable"
echo "$REPO_LINE" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

log "Dockerリポジトリ用にパッケージリストを更新..."
sudo apt update

log "Docker CE, CLI, containerd.io, Docker Compose plugin をインストール..."
# docker-compose-plugin の代わりに docker-compose をインストールする場合があるかもしれないので注意
# 今回は docker-compose-plugin を使用
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

LINUX_USER=$(whoami)
log "現在のユーザー ($LINUX_USER) を docker グループに追加..."
sudo usermod -aG docker "$LINUX_USER"
# グループ変更の即時反映に関する注意はPowerShell側で表示

log "Immich用のディレクトリとファイルを設定..."
mkdir -p "$IMMICH_DIR"
# cd コマンドの成功確認
if ! cd "$IMMICH_DIR"; then
    error_exit "$IMMICH_DIR へのディレクトリ変更に失敗しました。パスと権限を確認してください。"
fi

log "現在のディレクトリ: $(pwd)"
log "Immichのdocker-compose.ymlとexample.envをダウンロード..."
wget -qO docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
wget -qO .env https://github.com/immich-app/immich/releases/latest/download/example.env

log ".env ファイルをTimeZone: $TIME_ZONE で更新..."
# 既存のTZ行を削除 (コメントアウトされているものも含む) してから新しい行を追加
# sed を使用して TZ 行を確実に置換または追加
if grep -q '^#\? *TZ=' .env; then
    sed -i -e "s|^#\? *TZ=.*|TZ=$TIME_ZONE|" .env
else
    echo "TZ=$TIME_ZONE" >> .env
fi

log "ImmichのDockerイメージをプル中 (数分かかることがあります)..."
sudo docker compose pull

log "Immichコンテナを起動中..."
sudo docker compose up -d

log "ログインメッセージを抑制するために .hushlogin を作成..."
touch "$HOME/.hushlogin"

log "Immich用WSLセットアップスクリプトが正常に完了しました。"
log "Dockerグループへの所属を有効にするには、WSLセッションを再起動するか、現在のセッションで 'newgrp docker' を実行する必要があるかもしれません。"

exit 0