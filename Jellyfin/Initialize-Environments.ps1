#!/usr/bin/env pwsh

# ファイアウォールルールの設定値
$ruleName = "Jellyfin (TCP 8096)" # ルール名 (任意の名前に変更可能)
$portNumber = 8096               # 開放するポート番号
$protocol = "TCP"                # プロトコル (TCP)

# 新しい受信規則を作成してポートを開放
try {
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
} catch {
    Write-Host "ファイアウォールルール '$ruleName' の作成中にエラーが発生しました。" -ForegroundColor Red
    Write-Host "エラー詳細: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "PowerShellを管理者として実行しているか確認してください。" -ForegroundColor Yellow
}

# Enterキーを押すと終了します
Read-Host -Prompt "Press Enter to exit"