#Requires -RunAsAdministrator
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8 # ★1. 出力エンコーディングをUTF-8に設定

# ◆ 要確認 ◆ smartctl.exe の実際のパスに変更してください
$smartctlPath = "C:\Program Files\smartmontools\bin\smartctl.exe"
# ◆ チェック対象のディスク識別子のリスト ◆
$disks = @("/dev/sda", "/dev/sdb")

$overallStatus = "PASSED" # 全体のステータス (初期値: 正常)
$errorMessages = @()     # エラーメッセージ格納用配列
$checkedDisks = $disks -join ", " # PRTGメッセージ用にディスク名を結合

# smartctlが存在するか最初にチェック
if (-not (Test-Path $smartctlPath -PathType Leaf)) {
    $overallStatus = "FAILED"
    $errorMessages += "Script Error: smartctl.exe not found at $smartctlPath"
} else {
    # 各ディスクをループでチェック
    foreach ($disk in $disks) {
        $diskStatus = "UNKNOWN" # このディスクのステータス初期化
        try {
            # smartctlコマンドを実行し、健康状態を取得 (-H オプション)
            $result = & $smartctlPath -H $disk
            # 結果から 'SMART overall-health' の行を検索
            $healthLine = $result | Select-String -Pattern "SMART overall-health self-assessment test result:"

            # 健康状態が PASSED かどうかで判定
            if ($healthLine -match "PASSED") {
                $diskStatus = "PASSED"
            } else {
                $diskStatus = "FAILED"
                # PASSEDでない場合のエラーメッセージを追加
                $failReason = $healthLine -replace "SMART overall-health self-assessment test result:\s*", ""
                $errorMessages += "Disk $disk health check result: $failReason"
            }
        } catch {
            # smartctl実行自体のエラー
            $diskStatus = "FAILED"
            $errorMessageDetail = $_.Exception.Message.Trim() # エラーメッセージ取得
            $errorMessages += "Disk $disk : Error executing/parsing smartctl. ($errorMessageDetail)"
        }

        # このディスクの結果がFAILEDなら、全体のステータスもFAILEDにする
        if ($diskStatus -ne "PASSED") {
            $overallStatus = "FAILED"
        }
    } # End foreach loop
}

# --- PRTGへの出力 ---
Write-Host "<prtg>"
if ($overallStatus -eq "PASSED") {
    # 全ディスク正常時の出力
    Write-Host "  <result>"
    Write-Host "    <channel>SSD Health</channel>"       # チャンネル名
    Write-Host "    <value>1</value>"                        # 正常なら 1
    Write-Host "    <valuetext>PASSED ($checkedDisks)</valuetext>" # 表示テキスト (チェックしたディスク名を含む)
    Write-Host "    <LimitMode>1</LimitMode>"                 # 1=制限を有効にする
    Write-Host "    <LimitMinError>1</LimitMinError>"         # 1を下回ったら(つまり0になったら)エラー
    Write-Host "  </result>"
    Write-Host "  <text>All specified disks ($checkedDisks) reported PASSED.</text>" # センサーのメッセージ
} else {
    # 1つ以上のディスクで異常またはエラー発生時の出力
    $errorMessageText = $errorMessages -join " | " # 区切り文字で結合
    Write-Host "  <result>"
    Write-Host "    <channel>SSD Health</channel>"
    Write-Host "    <value>0</value>"                        # 異常なら 0
    Write-Host "    <valuetext>FAILED ($checkedDisks)</valuetext>" # 表示テキスト
    Write-Host "    <LimitMode>1</LimitMode>"                 # 1=制限を有効にする (エラータグが優先されるが念のため)
    Write-Host "    <LimitMinError>1</LimitMinError>"         # 1を下回ったら(つまり0になったら)エラー
    Write-Host "  </result>"
    Write-Host "  <error>1</error>"                          # PRTGにエラー状態を伝えるフラグ (これが最優先)
    Write-Host "  <text>SMART Health Check Failed! Issues: $errorMessageText</text>" # PRTGに表示されるエラーメッセージ (詳細を含む)
}
Write-Host "</prtg>"