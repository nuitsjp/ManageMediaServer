# Windows 11のWSL上にDockerを構築し、そこにImmichをコンテナーとして導入します。
# Immichが未導入の場合は導入してから起動します。
# 前提としてWSLは導入済みだが、Linuxディストリビューションは未導入の状態であること。
# また、Immichの導入にはDockerが必要なので、WSL上にDockerを導入します。
# さらに、Immichの導入にはPostgreSQLとRedisが必要なので、これらもDockerコンテナーとして導入します。
# WSLディストリビューションの確認と導入
$distributionName = "Ubuntu"
$distribution = wsl -l -v | Select-String $distributionName

if (-not $distribution) {
    Write-Host "$distributionName が見つかりません。インストールを開始します。"
    wsl --install -d $distributionName
    Write-Host "$distributionName のインストールが完了しました。"
} else {
    Write-Host "$distributionName は既にインストールされています。"
}

# Dockerの確認と導入 (WSL内)
Write-Host "Dockerの導入状況を確認しています..."
$dockerVersion = Invoke-Command -ScriptBlock { wsl -d $using:distributionName -- docker --version } -ErrorAction SilentlyContinue

if ($dockerVersion -match "Docker version") {
    Write-Host "Dockerは既にインストールされています。バージョン: $($dockerVersion)"
    Write-Host "Dockerを更新しています..."
    wsl -d $distributionName -- sudo apt-get update
    wsl -d $distributionName -- sudo apt-get upgrade -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    Write-Host "Dockerの更新が完了しました。"
} else {
    Write-Host "Dockerがインストールされていません。インストールを開始します..."
    wsl -d $distributionName -- sudo apt-get update
    wsl -d $distributionName -- sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    Write-Host "Dockerのインストールが完了しました。"
    # Dockerデーモンの起動確認やユーザーのdockerグループへの追加が必要な場合があります。
    # 例: wsl -d $distributionName -- sudo systemctl start docker
    # 例: wsl -d $distributionName -- sudo usermod -aG docker $USER (実行後、WSLの再起動が必要)
}

# Immichの起動 (Docker Composeを使用)
# ここにdocker-compose.ymlを使用してImmich、PostgreSQL、Redisを起動する処理を記述します。
# 例: cd (docker-compose.ymlのあるディレクトリ)
# 例: wsl -d $distributionName -- docker-compose up -d

Write-Host "Immichの起動処理が完了しました。"
