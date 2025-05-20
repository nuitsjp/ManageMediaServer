#!/usr/bin/env pwsh
#requires -RunAsAdministrator

param(
    [switch]$Force
)

. $PSScriptRoot\Modules\Functions.ps1

$ErrorActionPreference = 'Stop'

if (-not $Force) {
    $confirm = Read-Host "本当に Immich をアンインストールしてもよろしいですか？ (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "アンインストールを中止しました。"
        exit 0
    }
}

# Immich のアンインストール用スクリプト
# 1. ポートプロキシ設定の削除
Write-Host "[1/3] ポートプロキシ設定の削除中..."
netsh interface portproxy delete v4tov4 listenport=2283 listenaddress=0.0.0.0
Write-Host "[1/3] ポートプロキシ設定の削除完了"

# 2. Immich 用ファイアウォールルールの削除
Write-Host "[2/3] Immich 用ファイアウォールルールの削除中..."
Get-NetFirewallRule | Where-Object DisplayName -like "*Immich 2283*" | Remove-NetFirewallRule -Confirm:$false
Write-Host "[2/3] Immich 用ファイアウォールルールの削除完了"

# 3. WSL 上の Ubuntu の登録解除
Write-Host "[3/3] WSL 上の Ubuntu の登録解除中..."
wsl --unregister $script:DistroName
Write-Host "[3/3] WSL 上の Ubuntu の登録解除完了"

Write-Host "Immich のアンインストールが完了しました。"