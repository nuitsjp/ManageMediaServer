. $PSScriptRoot\Send-SlackNotification.ps1 # Send-SlackNotification.ps1をインポートして関数を使用

try {
    Send-SlackNotification -Status "成功" `
                           -Message "処理が正常に完了しました。"
} catch {
    Write-Error "通知に失敗しました: $($_.Exception.Message)"
}

try {
    throw "意図的なエラーを発生させました。"
} catch {
    Send-SlackNotification -Status "失敗" `
                           -Message "処理中にエラーが発生しました。" `
                           -Exception $_.Exception
}