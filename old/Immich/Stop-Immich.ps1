# Stop-Immich.ps1 - Dynamically generated based on Start-Immich.ps1

. "$PSScriptRoot\Modules\Functions.ps1"

$DistroName = $script:DistroName
$WSLUserName = $script:WSLUserName

$ErrorActionPreference = 'Stop'

# 例外処理をtrapで実装
trap {
    Write-Log "Immich停止中にエラーが発生しました: $($_.Exception.Message) | スタックトレース: $($_.ScriptStackTrace)" -Level "ERROR"
    exit 1
}

Write-Log "Immich停止処理を開始します..."

Write-Log "WSLディストリビューション '$DistroName' の実行状態を確認しています..."
$wslRunning = $false
try {
    # WSLディストリビューションが実行中かどうかを確認（エラー処理を無効化して実行）
    $ErrorActionPreference = 'SilentlyContinue'
    $wslStatus = wsl -d $DistroName --exec echo "running" 2>$null
    $ErrorActionPreference = 'Stop'    
    if ($wslStatus -eq "running") {
        $wslRunning = $true
        Write-Log "WSLディストリビューション '$DistroName' は実行中です。"
    } else {
        Write-Log "WSLディストリビューション '$DistroName' は実行されていません。処理は不要です。"
    }
} catch {
    Write-Log "WSLディストリビューション '$DistroName' は実行されていないか、利用できません。処理は不要です。"
}

if ($wslRunning) {
    Write-Log "'$script:ImmichDirWSL'でImmichサービスを停止しています（ユーザー: '$WSLUserName'）..."
    $WslCommand = "cd '$script:ImmichDirWSL' && docker compose down"

    Write-Log "WSLで実行: wsl -d $DistroName -u $WSLUserName -- bash -c $WslCommand"
    wsl -d $DistroName -u $WSLUserName -- bash -c "$WslCommand"
    Write-Log "Immichサービス停止コマンドを '$DistroName' に送信しました。"
    
    # WSLディストリビューションを停止
    Write-Log "WSLディストリビューション '$DistroName' を停止しています..."
    wsl --terminate $DistroName
    Write-Log "WSLディストリビューション '$DistroName' を停止しました。"
}

Write-Log "Stop-Immich.ps1 が正常に完了しました。"
exit 0