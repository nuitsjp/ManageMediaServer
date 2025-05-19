#!/usr/bin/env pwsh
# 管理者権限を推奨

# Windows 11のWSL上で動作しているImmichを停止するスクリプト

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\Modules\Functions.ps1

$distributionName = $script:DistroName

# Immich実行ディレクトリのパス
$immichDir = Join-Path $PSScriptRoot 'instance'
if (-not (Test-Path $immichDir)) {
    Write-Error "Immich実行ディレクトリが見つかりません: $immichDir"
    exit 1
}

# WSL内のパスを取得
$wslImmichDir = Convert-WindowsPathToWSLPath -WindowsPath $immichDir

# Docker Composeのバージョンを確認（新形式か旧形式か）
& wsl -d $distributionName -- docker compose version >$null 2>&1
$useNewCompose = $LASTEXITCODE -eq 0
$composeCommand = if ($useNewCompose) { "docker compose" } else { "docker-compose" }

# Immichサービスの状態確認
Write-Host "Immichサービスの状態を確認しています..."
$containersRunning = & wsl -d $distributionName -- bash -c "cd '$wslImmichDir' && $composeCommand ps -q | wc -l"
if ([int]$containersRunning -eq 0) {
    Write-Host "Immichサービスは既に停止しています。"
    exit 0
}

# Immichサービスの停止
Write-Host "Immichサービスを停止しています..."
& wsl -d $distributionName -- bash -c "cd '$wslImmichDir' && $composeCommand down"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Immichサービスの停止に失敗しました。"
    exit 1
}

Write-Host "Immichサービスは正常に停止しました。"