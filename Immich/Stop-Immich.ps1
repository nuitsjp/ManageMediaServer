#!/usr/bin/env pwsh
# 管理者権限を推奨

# Windows 11のWSL上で動作しているImmichを停止するスクリプト

$ErrorActionPreference = 'Stop'

# Functionsファイルの読み込み
. $PSScriptRoot\Functions.ps1

# Immich実行ディレクトリの存在確認
if (-not (Test-ImmichDirectory)) {
    exit 1
}

# WSL内のパスを取得
$wslImmichDir = ConvertTo-WslPath -WindowsPath $script:ImmichDir

# Docker Composeコマンドを取得
$composeCommand = Get-DockerComposeCommand

# Immichサービスの状態確認
Write-Log "Immichサービスの状態を確認しています..."
$containersRunning = & wsl -d $script:Distro -- bash -c "cd '$wslImmichDir' && $composeCommand ps -q | wc -l"
if ([int]$containersRunning -eq 0) {
    Write-Log "Immichサービスは既に停止しています."
    exit 0
}

# Immichサービスの停止
Write-Log "Immichサービスを停止しています..."
& wsl -d $script:Distro -- bash -c "cd '$wslImmichDir' && $composeCommand down"
if ($LASTEXITCODE -ne 0) {
    Write-Log "Immichサービスの停止に失敗しました." -Level ERROR
    exit 1
}

Write-Log "Immichサービスは正常に停止しました."