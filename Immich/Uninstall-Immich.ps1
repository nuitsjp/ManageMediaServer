#!/usr/bin/env pwsh
#requires -RunAsAdministrator

. $PSScriptRoot\Modules\Functions.ps1

# Immich のアンインストール用スクリプト
# 1. ポートプロキシ設定の削除
netsh interface portproxy delete v4tov4 listenport=2283 listenaddress=0.0.0.0

# 2. Immich 用ファイアウォールルールの削除
Get-NetFirewallRule | Where-Object DisplayName -like "*Immich 2283*" | Remove-NetFirewallRule -Confirm:$false

# 3. WSL 上の Ubuntu の登録解除
wsl --unregister $script:DistroName