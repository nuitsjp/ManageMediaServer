# ==============================================================================
# Slack通知関数
# 指定されたWebhook URLに、ステータスとメッセージ、エラー情報を送信します。
# ==============================================================================
function Send-SlackNotification {
    [CmdletBinding()] # Verbose出力などを有効にする
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("成功", "失敗", "警告", "情報")] # 想定されるステータスを指定
        [string]$Status,

        [Parameter(Mandatory=$true)]
        [string]$Message,

        # エラーが発生した場合に、そのエラーオブジェクト ($_.Exception) を渡す
        [Parameter(Mandatory=$false)]
        [System.Exception]$Exception,

        # オプション: Slack投稿者名やアイコンを変更する場合
        [Parameter(Mandatory=$false)]
        [string]$Username = "PowerShell Runner", # デフォルトの投稿者名

        [Parameter(Mandatory=$false)]
        [string]$IconEmoji = ":robot_face:"     # デフォルトのアイコン
    )

    . $PSScriptRoot\secrets.ps1 # secrets.ps1をインポートしてグローバル変数を取得

    $WebhookUrl = $global:SlackWebhookUrl # secrets.ps1から取得したWebhook URLを使用

    # Webhook URLが設定されているか、基本的な形式かを確認
    if (-not ($WebhookUrl -like "https://hooks.slack.com/services/*")) {
        Write-Error "無効なSlack Webhook URL、またはURLが設定されていません。通知は送信されません。"
        return # 関数を終了
    }

    # エラーオブジェクトが渡された場合は、メッセージに追加
    $DetailedMessage = $Message
    if ($PSBoundParameters.ContainsKey('Exception') -and $null -ne $Exception) {
        # エラーの主要なメッセージとスタックトレースの一部を含める
        $DetailedMessage += "`n--- エラー詳細 ---`n$($Exception.GetType().FullName): $($Exception.Message)`n$($Exception.StackTrace | Out-String | Select-Object -First 5)`n..." # スタックトレースは長くなりすぎるため一部抜粋
        # 必要であれば $Exception.ToString() で全て含めることも可能
        # $DetailedMessage += "`n--- エラー詳細 ---`n$($Exception.ToString())"
    }

    # Slackに送信するペイロードを作成
    $Payload = @{
        text       = "*[$Status]* `n$($DetailedMessage)" # コードブロックで整形
        username   = $Username
        icon_emoji = $IconEmoji
    } | ConvertTo-Json -Depth 4 -Compress # JSON形式に変換

    # Slackへ通知を実行
    try {
        Write-Verbose "Slackへ通知を送信します: Status=$Status, Message=$Message"
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $Payload -ContentType 'application/json' -ErrorAction Stop
        Write-Verbose "Slackへの通知が完了しました。"
    } catch {
        # Slack通知自体でエラーが発生した場合
        $NotificationErrorMessage = "Slackへの通知中にエラーが発生しました: $($_.Exception.Message)"
        Write-Error $NotificationErrorMessage
        try {
        # このエラーをイベントログに書き込む
        Write-EventLog -LogName Application -Source "BackupOneDrive" -EventId 1002 -EntryType Error -Message $NotificationErrorMessage
        }
        catch {
            # ignore
        }
    }
}
