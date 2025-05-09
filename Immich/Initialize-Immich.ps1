#!/usr/bin/env pwsh
#requires -RunAsAdministrator

[CmdletBinding()]param()

$ErrorActionPreference = 'Stop'

# --- 変更する場合はここだけ ---
$Distro     = "Ubuntu"          # 既定 Ubuntu をそのまま使用
$AppPort    = 2283              # Immich がリッスン/公開する TCP ポート
$TimeZone   = "Asia/Tokyo"      # .env 用タイムゾーン
$ImmichDir  = "~/immich"        # WSL 内の作業パス（~ は /home/<user>）
# --------------------------------

### 補助: 指定 Bash をディストロ内部で実行
function Invoke-WSL {
    param([string]$Command)
    wsl -d $Distro -- bash -c $Command
}

### 3‑1  ディストロが無ければインストール
if (-not (wsl -l -q | Select-String -SimpleMatch $Distro)) {
    Write-Host "[+] Ubuntu ディストロを導入 …"
    wsl --install -d Ubuntu --no-launch
}

### 3‑2  パッケージ準備（apt 更新・Docker Engine / compose‑plugin）
Write-Host "[+] apt 更新と Docker インストール …"
Invoke-WSL @"
set -euo pipefail
sudo apt update && sudo apt upgrade -y
sudo apt install -y ca-certificates curl gnupg lsb-release
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $(whoami)
"@

### 3‑3  Immich スタック取得 & .env 修正
Write-Host "[+] Immich 用 docker‑compose ファイル取得 …"
Invoke-WSL "mkdir -p $ImmichDir && cd $ImmichDir && \
  wget -qO docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml && \
  wget -qO .env https://github.com/immich-app/immich/releases/latest/download/example.env"

Invoke-WSL "sed -i '/^#\\? *TZ=.*/d' $ImmichDir/.env && echo 'TZ=$TimeZone' >> $ImmichDir/.env"

### 3‑4  イメージ取得 & 起動
Write-Host "[+] コンテナイメージ取得中（数分かかります）"
Invoke-WSL "cd $ImmichDir && docker compose pull && docker compose up -d"

### 3‑5  LAN 公開（mirrored モード時はスキップ）
$IsMirrored = (Get-Content ~/.wslconfig -ErrorAction SilentlyContinue | Select-String -SimpleMatch 'networkingMode=mirrored')
if (-not $IsMirrored) {
    Write-Host "[+] port‑proxy と Firewall を構成 …"
    $wslIp = (wsl -d $Distro hostname -I).Split()[0]
    netsh interface portproxy delete v4tov4 listenport=$AppPort proto=tcp 2>$null
    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$AppPort connectaddress=$wslIp connectport=$AppPort
    if (-not (Get-NetFirewallRule -DisplayName "Immich $AppPort" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Immich $AppPort" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $AppPort -Profile Any
    }
} else {
    Write-Host "[i] mirrored networking が有効 — port‑proxy をスキップ"
}

### 3‑6  完了メッセージ
$HostIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -notmatch 'vEthernet|Loopback'} | Select-Object -First 1 -ExpandProperty IPAddress)
Write-Host "[✓] ブラウザでアクセス: http://$($HostIP):$AppPort" -ForegroundColor Green