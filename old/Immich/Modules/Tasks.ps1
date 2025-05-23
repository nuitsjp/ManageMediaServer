. $PSScriptRoot\Common.ps1

function Register-ImmichStartupTask {
    [CmdletBinding()]
    param (
        [string]$StartImmichScriptPath,
        [string]$TaskName = "ImmichWSLAutoStart"
    )
    # タスクスケジューラーへ登録
    if (-not (Test-Path $StartImmichScriptPath)) {
        throw "$StartImmichScriptPath が見つかりません。Install-Immich.ps1 と同じディレクトリに配置してください。"
    }
    $CurrentWindowsUserIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $CurrentWindowsUserName = $CurrentWindowsUserIdentity.Name
    Write-Log "タスクの実行ユーザー: '$CurrentWindowsUserName'" -Level "INFO"
    $Principal = New-ScheduledTaskPrincipal `
                    -UserId $CurrentWindowsUserName `
                    -LogonType S4U `
                    -RunLevel Highest
    $PwshPath = (Get-Command pwsh).Source
    if ([string]::IsNullOrEmpty($PwshPath)) {
        throw "pwsh.exe が見つかりませんでした。"
    }
    $TaskDescription = "WSL ($script:DistroName) および Immich サービスをシステム起動時に自動起動します。実行ユーザー: $CurrentWindowsUserName"
    $TaskArguments = "-ExecutionPolicy Bypass -NoProfile -File `"$StartImmichScriptPath`""
    $Action    = New-ScheduledTaskAction   -Execute $PwshPath -Argument $TaskArguments
    $Trigger   = New-ScheduledTaskTrigger  -AtStartup
    $Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                                -DontStopIfGoingOnBatteries `
                                                -StartWhenAvailable `
                                                -RunOnlyIfNetworkAvailable:$false `
                                                -ExecutionTimeLimit ([TimeSpan]::Zero) `
                                                -RestartCount 3 `
                                                -RestartInterval (New-TimeSpan -Minutes 5) `
                                                -Compatibility Win8
    Write-Log "既存のタスク '$TaskName' があれば削除します..." -Level "INFO"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "タスク '$TaskName' をユーザー '$CurrentWindowsUserName' で登録します (S4U ログオンタイプ)..." -Level "INFO"
    Register-ScheduledTask `
        -TaskName    $TaskName `
        -Action      $Action `
        -Trigger     $Trigger `
        -Principal   $Principal `
        -Settings    $Settings `
        -Description $TaskDescription `
        -ErrorAction Stop | Out-Null
    Write-Log "タスク '$TaskName' をシステム起動時に '$StartImmichScriptPath' を実行するように登録/更新しました。" -Level "INFO"
}
