#!/bin/bash
# setup_immich_on_wsl.sh

# エラーが発生したらスクリプトを終了する
set -e

# --- パラメータ ---
# PowerShellスクリプトから引数として渡される
TIME_ZONE="$1"
IMMICH_DIR_PARAM="$2"
WSL_PASSWORD="$3"
WSL_USERNAME="ubuntu"

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
# ユーザー ubuntu の存在確認・作成
if id "$WSL_USERNAME" &>/dev/null; then
    log "ユーザー $WSL_USERNAME は既に存在します。"
else
    log "新規ユーザー $WSL_USERNAME を作成しています..."
    useradd -m -s /bin/bash "$WSL_USERNAME"
    usermod -aG sudo "$WSL_USERNAME"
    if [ -n "$WSL_PASSWORD" ]; then
        echo "$WSL_USERNAME:$WSL_PASSWORD" | chpasswd
        log "ユーザー $WSL_USERNAME のパスワードを設定しました。"
    else
        warn "パスワードが指定されていないため、パスワードなしでユーザーを作成しました。"
        warn "セキュリティのために手動でパスワードを設定することをお勧めします。"
    fi
    log "WSLのデフォルトユーザーを $WSL_USERNAME に設定しています..."
    echo "[user]" > /etc/wsl.conf
    echo "default=$WSL_USERNAME" >> /etc/wsl.conf
    log "WSLのデフォルトユーザー設定が完了しました。変更を適用するにはWSLの再起動が必要です。"
fi

# IMMICH_DIR_PARAM の解決 (~/ を展開)
# スクリプト実行ユーザーのホームディレクトリ基準で展開
if [[ "$IMMICH_DIR_PARAM" == "~/"* ]]; then
    # $HOME はスクリプト実行ユーザーのホームディレクトリ
    IMMICH_DIR="$HOME/${IMMICH_DIR_PARAM#\~/}"
else
    IMMICH_DIR="$IMMICH_DIR_PARAM"
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

# dockerグループに未所属なら追加、既に所属ならスキップ
if id -nG "$WSL_USERNAME" | grep -qw docker; then
    log "ユーザー $WSL_USERNAME はすでに docker グループに所属しています。"
else
    log "ユーザー $WSL_USERNAME を docker グループに追加..."
    sudo usermod -aG docker "$WSL_USERNAME"
fi

# dockerデーモンが起動していなければ自動起動
if ! sudo service docker status >/dev/null 2>&1; then
    log "Dockerデーモンを起動します..."
    sudo service docker start
else
    log "Dockerデーモンは既に起動しています。"
fi

log "Immich用のディレクトリとファイルを設定..."
sudo mkdir -p "$IMMICH_DIR"
sudo chown $(whoami):$(whoami) "$IMMICH_DIR"

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

log "ログインメッセージを抑制するために $WSL_USERNAME の .hushlogin を作成..."
sudo -u "$WSL_USERNAME" touch "/home/$WSL_USERNAME/.hushlogin"

log "Immich用WSLセットアップスクリプトが正常に完了しました。"
log "Dockerグループへの所属を有効にするには、WSLセッションを再起動するか、現在のセッションで 'newgrp docker' を実行する必要があるかもしれません。"

exit 0