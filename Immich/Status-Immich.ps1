#!/usr/bin/env pwsh
# 管理者権限を推奨

# Windows 11のWSL上で動作しているImmichの状態を確認するスクリプト

$ErrorActionPreference = 'Stop'

$distributionName = "Ubuntu"

# Functionsファイルの読み込み
. $PSScriptRoot\Functions.ps1

# Immich実行ディレクトリのパス
$immichDir = Join-Path $PSScriptRoot 'instance'
if (-not (Test-Path $immichDir)) {
    Write-Error "Immich実行ディレクトリが見つかりません: $immichDir"
    exit 1
}

# WSL内のパスを取得
$wslImmichDir = ConvertTo-WslPath -WindowsPath $immichDir -DistributionName $distributionName

# Docker Composeのバージョンを確認（新形式か旧形式か）
& wsl -d $distributionName -- docker compose version >$null 2>&1
$useNewCompose = $LASTEXITCODE -eq 0
$composeCommand = if ($useNewCompose) { "docker compose" } else { "docker-compose" }

# Immichサービスの状態確認
Write-Host "Immichサービスの状態を確認しています..."

# コンテナの一覧を表示
Write-Host "`nコンテナの状態:"
& wsl -d $distributionName -- bash -c "cd '$wslImmichDir' && $composeCommand ps"

# ログの確認（最後の10行）
Write-Host "`n最近のログ:"
& wsl -d $distributionName -- bash -c "cd '$wslImmichDir' && $composeCommand logs --tail=10"

# ヘルスチェック
Write-Host "`nImmichサーバーの接続確認:"
try {
    $response = Invoke-WebRequest -Uri "http://localhost:2283/api/server-info/ping" -Method GET -TimeoutSec 5 -ErrorAction SilentlyContinue
    if ($response.StatusCode -eq 200) {
        Write-Host "Immichサーバーは正常に応答しています。" -ForegroundColor Green
    } else {
        Write-Host "Immichサーバーは応答していますが、正常ではありません。ステータスコード: $($response.StatusCode)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Immichサーバーに接続できません。サービスが起動していないか、問題が発生しています。" -ForegroundColor Red
}

Write-Host "`nImmichサービスへのアクセス方法: http://localhost:2283"
