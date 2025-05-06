#Requires -RunAsAdministrator
# ◆ 要確認 ◆ smartctl.exe の実際のパスに変更してください
$smartctlPath = "C:\Program Files\smartmontools\bin\smartctl.exe"
# ◆ このスクリプトが監視するディスク識別子 ◆
$disk = "/dev/sda"

try {
    # smartctlコマンドを実行し、健康状態を取得 (-H オプション)
    $result = & $smartctlPath -H $disk
    # 結果から 'SMART overall-health' の行を検索
    $healthLine = $result | Select-String -Pattern "SMART overall-health self-assessment test result:"

    # 健康状態が PASSED かどうかで判定
    if ($healthLine -match "PASSED") {
        # 正常時のPRTG向けXML出力
        Write-Host "<prtg>"
        Write-Host "  <result>"
        Write-Host "    <channel>Health Status</channel>" # PRTGに表示されるチャンネル名
        Write-Host "    <value>1</value>" # 正常なら 1
        Write-Host "    <valuetext>PASSED</valuetext>" # 表示テキスト
        Write-Host "    <LimitMode>1</LimitMode>" # 1=異常時にエラー (Down)
        Write-Host "    <LimitMaxError>0</LimitMaxError>" # 0以下 (つまり0) ならエラー状態
        Write-Host "  </result>"
        Write-Host "</prtg>"
    } else {
        # 異常時のPRTG向けXML出力
        Write-Host "<prtg>"
        Write-Host "  <result>"
        Write-Host "    <channel>Health Status</channel>"
        Write-Host "    <value>0</value>" # 異常なら 0
        Write-Host "    <valuetext>FAILED or Unknown</valuetext>" # 表示テキスト
        Write-Host "    <LimitMode>1</LimitMode>"
        Write-Host "    <LimitMaxError>0</LimitMaxError>"
        Write-Host "  </result>"
        Write-Host "  <error>1</error>" # PRTGにエラー状態を伝えるフラグ
        Write-Host "  <text>SMART Health Check Failed or Unknown Status for $disk</text>" # PRTGに表示されるエラーメッセージ
        Write-Host "</prtg>"
    }
} catch {
    # スクリプト自体の実行エラー
    Write-Host "<prtg>"
    Write-Host "  <error>1</error>"
    Write-Host "  <text>Script Error for $disk : $($_.Exception.Message)</text>" # エラーメッセージ
    Write-Host "</prtg>"
}