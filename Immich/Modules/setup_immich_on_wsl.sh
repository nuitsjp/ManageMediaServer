#!/bin/bash
# setup_immich_on_wsl.sh

# エラーが発生したらスクリプトを終了する
set -e

# --- パラメータ ---
# PowerShellスクリプトから引数として渡される
TIME_ZONE="$1"
USER_PASSWORD="$2"
IMMICH_EXTERNAL_LIBRARY_PATH="$3"

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
if [ ! -f "/opt/immich/docker-compose.yml" ] && [ -z "$IMMICH_EXTERNAL_LIBRARY_PATH" ]; then
    error_exit "/opt/immich/docker-compose.yml が存在せず、かつ IMMICH_EXTERNAL_LIBRARY_PATH パラメータが未指定です。セットアップを中断します。"
fi

log "パッケージリストを更新中..."
sudo apt update

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

log "Immich用のディレクトリとファイルを設定..."
IMMICH_DIR="/opt/immich"
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

if [ -n "$IMMICH_EXTERNAL_LIBRARY_PATH" ]; then
    log "docker-compose.yml に外部ライブラリマウントを追加..."
    sed -i "/- \/etc\/localtime:\/etc\/localtime:ro/a\      - ${IMMICH_EXTERNAL_LIBRARY_PATH}:/usr/src/app/external-library" docker-compose.yml
fi

log "ImmichのDockerイメージをプル中 (数分かかることがあります)..."
sudo docker compose pull

log "Immichコンテナを起動中..."
sudo docker compose up -d


# USER_PASSWORDが指定されていたらubuntuユーザーを作成しパスワードを設定
if [ -n "$USER_PASSWORD" ]; then
    log "ubuntuユーザーを作成または既存ユーザーのパスワードを設定..."
    if id "ubuntu" &>/dev/null; then
        echo "ubuntu:$USER_PASSWORD" | sudo chpasswd
        log "既存のubuntuユーザーのパスワードを更新しました。"
    else
        sudo useradd -m -s /bin/bash ubuntu
        echo "ubuntu:$USER_PASSWORD" | sudo chpasswd

        log "ログインメッセージを抑制するために .hushlogin を作成..."
        touch "/home/ubuntu/.hushlogin"

        log "ubuntuのデフォルトシェルを bash に変更"
        sudo chsh -s /bin/bash ubuntu

        log "ubuntu を docker グループに追加"
        sudo usermod -aG docker ubuntu

        log "ubuntu を root グループに設定"
        sudo usermod -aG sudo ubuntu

        log "新規ubuntuユーザーを作成しパスワードを設定しました。"
    fi
fi

exit 0