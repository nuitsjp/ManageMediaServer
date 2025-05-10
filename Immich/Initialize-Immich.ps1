#!/usr/bin/env pwsh
#requires -RunAsAdministrator
[CmdletBinding()]param()

# --- 変更する場合はここだけ -----------------
$Distro    = "Ubuntu"      # 既定 Ubuntu
$AppPort   = 2283          # Immich がリッスンする TCP ポート
$TimeZone  = "Asia/Tokyo"  # .env 用タイムゾーン
$ImmichDir = "~/immich"    # WSL 内の作業パス
# -------------------------------------------

### 3-1 ディストロが無ければ導入
if ((wsl -l -q) -notcontains $Distro) {
    Write-Host "[+] Ubuntu ディストロを導入 …"
    wsl --install -d $Distro --no-launch
}

### 3-2 apt 更新 & Docker インストール
Write-Host "[+] apt 更新と Docker インストール …"

# Ubuntu コードネームを PowerShell 側で取得
$release  = (wsl -d $Distro -- lsb_release -cs).Trim()
$repoLine = "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $release stable"
$linuxUser = (wsl -d $Distro -- whoami).Trim()

# すべて 1 行に連結（`r` を除去して CR 問題を回避）
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

### 3-3 Immich スタック取得 & .env 修正
Write-Host "[+] Immich 用 docker-compose ファイル取得 …"
$initCmd = @"
mkdir -p $ImmichDir && cd $ImmichDir && \
wget -qO docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml && \
wget -qO .env               https://github.com/immich-app/immich/releases/latest/download/example.env && \
sed -i '/^#\? *TZ=.*/d' .env && echo 'TZ=$TimeZone' >> .env
"@ -replace "`r",""

wsl -d $Distro -- bash -c "$initCmd"

### 3-4 イメージ取得 & 起動
Write-Host "[+] コンテナイメージ取得中（数分かかります）"
$upCmd = "cd $ImmichDir && sudo docker compose pull && sudo docker compose up -d"
wsl -d $Distro -- bash -c "$upCmd"

### 3-5 LAN 公開
Write-Host "[+] port-proxy と Firewall を構成 …"

# ① WSL の最初の IPv4 を取得
$wslIp = (wsl -d $Distro -- hostname -I).Split() |
         Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
         Select-Object -First 1

if ($wslIp) {

    # ② 既に登録済みか確認
    $existing = netsh interface portproxy show v4tov4 |
                Select-String " 0\.0\.0\.0\s+$AppPort\s+"   # listenaddress=0.0.0.0 かつ listenport=$AppPort

    if ($existing) {
        # 見つかった場合のみ削除
        netsh interface portproxy delete v4tov4 `
            listenaddress=0.0.0.0 listenport=$AppPort proto=tcp | Out-Null
    }

    # ③ 新しいエントリを追加（削除後でも未登録でも OK）
    netsh interface portproxy add v4tov4 `
        listenaddress=0.0.0.0 listenport=$AppPort `
        connectaddress=$wslIp   connectport=$AppPort | Out-Null

    # ④ Firewall ルール（無ければ作成）
    if (-not (Get-NetFirewallRule -DisplayName "Immich $AppPort" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Immich $AppPort" -Direction Inbound -Action Allow `
                            -Protocol TCP -LocalPort $AppPort -Profile Any | Out-Null
    }

} else {
    Write-Warning "WSL IPv4 が取得できず port-proxy をスキップしました。手動で確認してください。"
}

    ### 3-6 完了メッセージ
$HostIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch 'vEthernet|Loopback' } | Select-Object -First 1 -ExpandProperty IPAddress)
Write-Host "[✓] ブラウザでアクセス: http://$HostIP`:$AppPort" -ForegroundColor Green
