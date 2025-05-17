#!/usr/bin/env pwsh
#requires -RunAsAdministrator

# --- 1- パラメーター定義・ログ設定・例外処理 -----------------------------------
[CmdletBinding()]
Param(
    [int]   $AppPort  = 2283,
    [string]$TimeZone = 'Asia/Tokyo'
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\Functions.ps1

trap {
    Write-Error $Message
    exit 1
}

# --- 2- WSLディストロの導入 ------------------------------------------------
$Distro = $script:DistroName
$WSLUserName = $script:WSLUserName
$UserPassword = ''
if ((wsl -l -q) -notcontains $Distro) {
    Write-Log "WSLディストリビューション '$Distro' にユーザー '$WSLUserName' を作成します。"
    $UserPassword = Read-PasswordTwice
    Write-Log "$Distro ディストロを導入 …"
    wsl --install -d $Distro
}
elseif (-not (Test-WSLUserExists -UserName $WSLUserName -Distro $Distro)) {
    Write-Log "WSLディストリビューション '$Distro' にユーザー '$WSLUserName' が存在しません。新規作成します。"
    $UserPassword = Read-PasswordTwice
}

Write-Log "パッケージの更新と、dos2unixのインストールをしています..."
wsl -d $Distro -- bash -c "sudo apt-get update && sudo apt-get install -y dos2unix"

# --- 3- WSL内セットアップスクリプトの実行 ------------------------------------
Write-Log "WSL内セットアップスクリプトの準備と実行..."
Invoke-WSLCopyAndRunScript -ScriptFileName "setup_immich_on_wsl.sh" -Distro $Distro -Arguments @($TimeZone, $UserPassword)

# --- 7- Windows起動時のImmich自動起動設定 (Task Scheduler) ---
Write-Log "Windows起動時のImmich自動起動を設定します..."

try {
    # Start-Immich.ps1 が物理的に存在することを前提とする
    $StartImmichScriptName = "Start-Immich.ps1"
    $StartImmichScriptPath = Join-Path -Path $PSScriptRoot -ChildPath $StartImmichScriptName

    if (-not (Test-Path $StartImmichScriptPath)) {
        throw "$StartImmichScriptPath が見つかりません。Install-Immich.ps1 と同じディレクトリに配置してください。"
    }

    # WSLのデフォルトユーザー名を取得
    $WSLDefaultUser = $WSLUserName
    Write-Log "WSL Default User: $WSLDefaultUser"

    # タスクスケジューラに登録
    $TaskName = "ImmichWSLAutoStart"
    $PwshPath = (Get-Command pwsh).Source
    if ([string]::IsNullOrEmpty($PwshPath)) {
        Write-Log "pwsh.exe が見つかりませんでした。" 'ERROR'; throw "pwsh.exe not found."
    }

    $CurrentWindowsUserIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $CurrentWindowsUserName = $CurrentWindowsUserIdentity.Name
    Write-Log "タスクの実行ユーザーとして現在のWindowsユーザー '$CurrentWindowsUserName' を使用します。"

    # S4U ログオンタイプを使ってパスワード不要で登録
    $Principal = New-ScheduledTaskPrincipal `
                    -UserId $CurrentWindowsUserName `
                    -LogonType S4U `
                    -RunLevel Highest

    $TaskDescription = "Automatically starts WSL ($Distro) and Immich services at system startup using $StartImmichScriptName. Runs as $CurrentWindowsUserName."
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

    Write-Log "既存のタスク '$TaskName' があれば削除します..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    Write-Log "タスク '$TaskName' をユーザー '$CurrentWindowsUserName' で登録試行 (S4U ログオンタイプを使用します)..."
    Register-ScheduledTask `
        -TaskName    $TaskName `
        -Action      $Action `
        -Trigger     $Trigger `
        -Principal   $Principal `
        -Settings    $Settings `
        -Description $TaskDescription `
        -ErrorAction Stop | Out-Null

    Write-Log "タスク '$TaskName' をシステム起動時に '$StartImmichScriptPath' を実行するように登録/更新しました。"

} catch {
    Write-Log "自動起動設定中にエラーが発生しました: $($_.Exception.Message)" 'ERROR'
    Write-Log "  発生したコマンドレット: $($_.TargetObject)" 'ERROR'
    Write-Log "スクリプトが管理者権限で実行されているか、指定したユーザー (`$CurrentWindowsUserName`) の設定を確認してください。" 'WARN'
}

# --- (既存のスクリプトの最終的な完了メッセージやexitの前にこのセクションを配置) ---
Write-Log "Install-Immich.ps1 の処理が完了しました。"