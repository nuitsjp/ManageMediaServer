#!/usr/bin/env pwsh
#Requires -RunAsAdministrator

# ファイアウォールルールの設定値
$portNumber = 8096
$ruleName = "Jellyfin (TCP $($portNumber))"
$protocol = "TCP"

# 既存の同名ルールがあれば削除 (エラー無視)
Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

# 新しいルールを作成
New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound `
    -LocalPort $portNumber `
    -Protocol $protocol `
    -Action Allow `
    -Profile Any `
    -Enabled True `
    -ErrorAction Stop
Write-Host "ファイアウォールルール '$ruleName' が正常に作成され、ポート $portNumber ($protocol) が開放されました。" -ForegroundColor Green
