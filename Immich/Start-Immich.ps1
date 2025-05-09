#!/usr/bin/env pwsh

# Windows 11のWSL上にDockerを構築し、そこにImmichをコンテナーとして導入します。
# Immichが未導入の場合は導入してから起動します。
# 前提としてWSLは導入済みだが、Linuxディストリビューションは未導入の状態であること。
# また、Immichの導入にはDockerが必要なので、WSL上にDockerを導入します。
# さらに、Immichの導入にはPostgreSQLとRedisが必要なので、これらもDockerコンテナーとして導入します。
# WSLディストリビューションの確認と導入
$distributionName = "Ubuntu"

# Dockerの確認と導入 (WSL内)
Write-Host "Dockerの導入状況を確認しています..."
# Dockerの確認
& wsl -d $distributionName -- docker --version >$null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Dockerが検出されませんでした。WSL上にDockerをインストールします..."
    & wsl -d $distributionName -- sudo apt update
    & wsl -d $distributionName -- sudo apt install -y docker.io
    & wsl -d $distributionName -- sudo service docker start
    Write-Host "Dockerのインストールと起動が完了しました。"
} else {
    Write-Host "Dockerは既にインストールされています。"
}
# Dockerバージョンの表示
$dockerVersion = & wsl -d $distributionName -- docker --version
Write-Host "Dockerバージョン: $dockerVersion"

# 環境変数取得用関数定義
function Get-OrSet-Env {
    param(
        [string]$EnvName,
        [string]$PromptName,
        [string]$DefaultValue
    )
    $val = [Environment]::GetEnvironmentVariable($EnvName,'Machine')
    if (-not $val) {
        $ans = Read-Host "$PromptName の既定値: $DefaultValue でよろしいですか？ [Y/N]"
        if ($ans -match '^[Nn]') {
            $val = Read-Host "$PromptName を入力してください"
        } else {
            $val = $DefaultValue
        }
        [Environment]::SetEnvironmentVariable($EnvName,$val,'Machine')
        Write-Host "$PromptName を登録しました: $val"
    } else {
        Write-Host "$PromptName: $val (環境変数から取得)"
    }
    return $val
}

# アップロード先とDBデータ保存先を共通関数で設定
$uploadLocation    = Get-OrSet-Env -EnvName 'IMMICH_UPLOAD_LOCATION'    -PromptName 'UPLOAD_LOCATION'    -DefaultValue 'C:\immich-photos'
$dbDataLocation    = Get-OrSet-Env -EnvName 'IMMICH_DB_DATA_LOCATION'   -PromptName 'DB_DATA_LOCATION' -DefaultValue 'C:\immich-postgres'

# downloadsフォルダ作成とファイル取得
$downloadsDir = Join-Path $PSScriptRoot 'downloads'
if (-not (Test-Path $downloadsDir)) {
    Write-Host "downloadsフォルダを作成します: $downloadsDir"
    New-Item -ItemType Directory -Path $downloadsDir | Out-Null
} else {
    Write-Host "downloadsフォルダは既に存在します: $downloadsDir"
}
$files = @{
    'https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml' = 'docker-compose.yml'
    'https://github.com/immich-app/immich/releases/latest/download/example.env'        = 'example.env'
}
foreach ($url in $files.Keys) {
    $dest = Join-Path $downloadsDir $files[$url]
    if (-not (Test-Path $dest)) {
        Write-Host "ダウンロード中: $($files[$url])"
        Invoke-WebRequest -Uri $url -OutFile $dest
    } else {
        Write-Host "既に存在するためスキップ: $($files[$url])"
    }
}
