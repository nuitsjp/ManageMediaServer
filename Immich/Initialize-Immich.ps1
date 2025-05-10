#!/usr/bin/env pwsh
#requires -RunAsAdministrator

# --- 1- パラメーター定義・ログ設定・例外処理 -----------------------------------
Param(
    [string]$Distro   = 'Ubuntu',
    [int]   $AppPort  = 2283,
    [string]$TimeZone = 'Asia/Tokyo',
    [string]$ImmichDir= '~/immich',
    [switch]$VerboseMode
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    switch ($Level) {
        'INFO' { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        'WARN' { Write-Warning $Message }
        'ERROR'{ Write-Error $Message }
    }
}

# 任意の例外をキャッチしてスクリプトを中断
trap {
    Write-Log "予期せぬエラーが発生しました: $_" 'ERROR'
    exit 1
}
# --------------------------------------------------------------------------

# --- 2- WSLディストロの導入 ------------------------------------------------
if ((wsl -l -q) -notcontains $Distro) {
    Write-Log "Ubuntu ディストロを導入 …"
    wsl --install -d $Distro
}

# --- 3- apt更新 & Dockerインストール ---------------------------------------
Write-Log "apt 更新と Docker インストール …"

$release  = (wsl -d $Distro -- lsb_release -cs).Trim()
$repoLine = "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $release stable"
$linuxUser = (wsl -d $Distro -- whoami).Trim()

$installCmd = @"
sudo apt update && sudo apt upgrade -y && \
sudo apt install -y ca-certificates curl gnupg lsb-release && \
sudo mkdir -p /etc/apt/keyrings && \
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null && \
sudo chmod a+r /etc/apt/keyrings/docker.asc && \
echo '$repoLine' | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null && \
sudo apt update && \
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin && \
sudo usermod -aG docker $linuxUser
"@ -replace "`r",""

wsl -d $Distro -- bash -c "$installCmd"

# --- 4- Immichスタック取得 & .env修正 --------------------------------------
Write-Log "Immich 用 docker-compose ファイル取得 …"
$initCmd = @"
mkdir -p $ImmichDir && cd $ImmichDir && \
wget -qO docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml && \
wget -qO .env               https://github.com/immich-app/immich/releases/latest/download/example.env && \
sed -i '/^#\? *TZ=.*/d' .env && echo 'TZ=$TimeZone' >> .env
"@ -replace "`r",""

wsl -d $Distro -- bash -c "$initCmd"

# --- 5- イメージ取得 & 起動 ------------------------------------------------
Write-Log "コンテナイメージ取得中（数分かかります）"
$upCmd = "cd $ImmichDir && sudo docker compose pull && sudo docker compose up -d"
wsl -d $Distro -- bash -c "$upCmd"
wsl -d $Distro -- bash -c "touch ~/.hushlogin"

# --- 6- WSL対話セッション --------------------------------------------------
Write-Host @"

=========== WSL対話セッション ===========
これからWSLの対話セッションを開始します。

初回起動時は、以下を求められます:
1. デフォルトユーザー(ubuntu)のパスワード設定
2. その他必要に応じて設定を変更

セットアップが完了したら、'exit'と入力してWSLを終了してください。
======================================

"@ -ForegroundColor Cyan

Write-Log "WSL対話セッションを開始します..."
wsl -d $Distro

# --- 7- LAN公開 (port-proxyとFirewall構成) -------------------------------
Write-Log "port-proxy と Firewall を構成 …"

$wslIp = (wsl -d $Distro -- hostname -I).Split() |
         Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
         Select-Object -First 1

if ($wslIp) {
    $existing = netsh interface portproxy show v4tov4 |
                Select-String " 0\.0\.0\.0\s+$AppPort\s+"   # listenaddress=0.0.0.0 かつ listenport=$AppPort

    if ($existing) {
        netsh interface portproxy delete v4tov4 `
            listenaddress=0.0.0.0 listenport=$AppPort proto=tcp | Out-Null
    }

    netsh interface portproxy add v4tov4 `
        listenaddress=0.0.0.0 listenport=$AppPort `
        connectaddress=$wslIp   connectport=$AppPort | Out-Null

    if (-not (Get-NetFirewallRule -DisplayName "Immich $AppPort" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Immich $AppPort" -Direction Inbound -Action Allow `
                            -Protocol TCP -LocalPort $AppPort -Profile Any | Out-Null
    }

} else {
    Write-Warning "WSL IPv4 が取得できず port-proxy をスキップしました。手動で確認してください。"
}

# --- 8- 完了メッセージ -----------------------------------------------------
Write-Log "セットアップが完了しました"