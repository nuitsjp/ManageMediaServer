#!/usr/bin/env pwsh
#requires -RunAsAdministrator

# --- 1- パラメーター定義・ログ設定・例外処理 -----------------------------------
Param(
    [string]$Distro   = 'Ubuntu',
    [int]   $AppPort  = 2283,
    [string]$TimeZone = 'Asia/Tokyo',
    [switch]$VerboseMode
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    switch ($Level) {
        'INFO' { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        'WARN' { Write-Warning $Message }
        'ERROR'{ Write-Error $Message }
    }
}

trap {
    Write-Log "予期せぬエラーが発生しました: $_" 'ERROR'
    exit 1
}

# --- 2- WSLディストロの導入 ------------------------------------------------
if ((wsl -l -q) -notcontains $Distro) {
    Write-Log "$Distro ディストロを導入 …"
    wsl --install -d $Distro
    Write-Log "$Distro のインストールが完了しました。初回セットアップのため、一度手動で $Distro を起動し、ユーザー作成とパスワード設定を完了させてから、再度このスクリプトを実行してください。"
    Write-Log "または、このスクリプトがWSLの初回ユーザー作成を検知して対話セッションを開始するまでお待ちください。"
    # WSLのインストール直後はユーザー作成プロンプトが出るため、一旦終了するか、ユーザーに手動起動を促す
    # スクリプトが続行されても、次のwslコマンドでユーザー作成プロンプトが出るはず
}

# --- 3- WSL内セットアップスクリプトの実行 ------------------------------------
Write-Log "WSL内セットアップスクリプトの準備と実行..."

# setup_immich_on_wsl.sh がこのスクリプトと同じディレクトリにあると仮定
$WslSetupScriptName = "setup_immich_on_wsl.sh"
$WslSetupScriptPathOnWindows = Join-Path -Path $PSScriptRoot -ChildPath $WslSetupScriptName

if (-not (Test-Path $WslSetupScriptPathOnWindows)) {
    Write-Log "$WslSetupScriptPathOnWindows が見つかりません。PowerShellスクリプトと同じディレクトリに配置してください。" 'ERROR'
    exit 1
}

# WindowsパスをWSLパスに変換 (コピー元として使用)
try {
    # パスを正しく変換する
    # 引用符を付けずにパスを渡し、結果から余分な引用符を削除
    $WslPathCmd = "wsl -d $Distro -- wslpath '$($WslSetupScriptPathOnWindows.Replace('\', '\\'))'"
    $SourcePathOnWSL = (Invoke-Expression $WslPathCmd).Trim().Replace('"', '')
    
    # 変換結果を確認（トラブルシューティング用）
    if ($VerboseMode) {
        Write-Log "Windows Path: $WslSetupScriptPathOnWindows"
        Write-Log "WSL Path: $SourcePathOnWSL"
    }
    
    # パスが空でないか確認
    if ([string]::IsNullOrEmpty($SourcePathOnWSL)) {
        throw "WSLパスの変換結果が空です"
    }
} catch {
    Write-Log "WindowsパスからWSLパスへの変換に失敗しました。WSLが正しくインストールされ、$Distro が利用可能か確認してください。" 'ERROR'
    Write-Log "エラー詳細: $($_.Exception.Message)"
    exit 1
}

# WSL内のコピー先パス (例: /tmp 配下)
$DestinationScriptNameOnWSL = "setup_immich_for_distro.sh" # 汎用的な名前に変更も可
$DestinationPathOnWSL = "/tmp/$DestinationScriptNameOnWSL"

# インストールパスを固定
$ImmichDirPath = "/opt/immich"

# WSL内でスクリプトをコピーし、権限付与、改行コード変換、実行
# dos2unix がインストールされていない場合に備えてインストールコマンドも追加
$WslCommands = @"
sudo apt-get update && sudo apt-get install -y dos2unix && \
cp '$SourcePathOnWSL' '$DestinationPathOnWSL' && \
dos2unix '$DestinationPathOnWSL' && \
chmod +x '$DestinationPathOnWSL' && \
'$DestinationPathOnWSL' '$TimeZone' '$ImmichDirPath'
"@ -replace "`r","" # PowerShellヒアストリングのCRLFをLFに（念のため）

Write-Log "WSL内で以下のコマンド群を実行します:"
Write-Log $WslCommands # デバッグ用に表示

try {
    wsl -d $Distro -- bash -c "$WslCommands"
    Write-Log "WSL内セットアップスクリプトの実行が完了しました。"
    Write-Log "Dockerグループへの所属を完全に有効にするには、WSLセッション($Distro)を再起動するか、WSL内で 'newgrp docker' コマンドを実行してください。"
} catch {
    Write-Log "WSL内セットアップスクリプトの実行中にエラーが発生しました。" 'ERROR'
    Write-Log "エラー詳細: $($_.Exception.Message)"
    # WSLコマンドの標準エラー出力を表示したい場合
    if ($_.Exception.ErrorRecord.TargetObject -is [System.Management.Automation.ErrorRecord]) {
        Write-Log "WSLからのエラー出力: $($_.Exception.ErrorRecord.TargetObject.Status)"
    }
    exit 1
}

# --- 4- WSL対話セッション (ユーザーによる確認・初回パスワード設定用) -----------
# このセクションはユーザーの希望により維持
Write-Host @"

=========== WSL対話セッション ===========
Immichの基本的なセットアップは完了しました。
WSLの対話セッションを開始します。

WSLディストリビューションの初回起動時、またはユーザーが未設定の場合、
デフォルトユーザーのパスワード設定などが求められることがあります。

Dockerグループの変更を有効にするために `exit` してから再度ログインするか、
`newgrp docker` を実行すると `docker` コマンドが `sudo` なしで利用可能になります。
（上記セットアップスクリプト内で `sudo docker compose` を使用しているため、Immichは既に起動試行されています）

セットアップの確認や追加設定が完了したら、'exit'と入力してWSLを終了してください。
======================================

"@ -ForegroundColor Cyan

Write-Log "WSL対話セッションを開始します..."
wsl -d $Distro # ここでユーザーが初回パスワード設定などを行う想定

# --- 5- LAN公開 (port-proxyとFirewall構成) -------------------------------
# このセクションは変更なし (元のスクリプトのセクション7に相当)
Write-Log "port-proxy と Firewall を構成 …"

$wslIp = ""
try {
    $wslIp = (wsl -d $Distro -- hostname -I).Split() |
             Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
             Select-Object -First 1
} catch {
    Write-Log "WSL IPアドレスの取得に失敗しました。WSLが実行されているか確認してください。" 'WARN'
}


if ($wslIp) {
    Write-Log "WSL IPアドレス: $wslIp"
    $existingRule = Get-NetFirewallPortFilter -Protocol TCP | Where-Object { $_.LocalPort -eq $AppPort }
    $portProxyExists = netsh interface portproxy show v4tov4 | Select-String "0\.0\.0\.0\s+$AppPort\s+$wslIp\s+$AppPort"

    # Portproxy設定
    if ($portProxyExists) {
        Write-Log "既存のportproxy設定が見つかりました。更新は行いません。"
    } else {
        # 他のIPへの既存設定があれば削除
        $anyExistingProxy = netsh interface portproxy show v4tov4 | Select-String "0\.0\.0\.0\s+$AppPort\s+"
        if ($anyExistingProxy) {
            Write-Log "ポート $AppPort に対する既存のportproxy設定を削除します..."
            netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$AppPort proto=tcp | Out-Null
        }
        Write-Log "portproxy を追加: 0.0.0.0:$AppPort -> $($wslIp):$AppPort"
        netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$AppPort connectaddress=$wslIp connectport=$AppPort proto=tcp | Out-Null
    }

    # Firewall設定
    $firewallRuleName = "Immich (WSL Port $AppPort)"
    if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
        Write-Log "Firewallルール '$firewallRuleName' を追加..."
        New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -Action Allow `
                            -Protocol TCP -LocalPort $AppPort -Profile Any | Out-Null
    } else {
        Write-Log "既存のFirewallルール '$firewallRuleName' が見つかりました。"
    }

} else {
    Write-Warning "WSL IPv4 が取得できず port-proxy および Firewall の構成をスキップしました。WSL内でImmichが起動しているか、手動で確認してください。"
}

# --- 7- Windows起動時のImmich自動起動設定 (Task Scheduler) ---
Write-Log "Windows起動時のImmich自動起動を設定します..."

try {
    # Start-Immich.ps1 が物理的に存在することを前提とする
    $StartImmichScriptName = "Start-Immich.ps1"
    $StartImmichScriptPath = Join-Path -Path $PSScriptRoot -ChildPath $StartImmichScriptName

    if (-not (Test-Path $StartImmichScriptPath)) {
        Write-Log "$StartImmichScriptPath が見つかりません。Install-Immich.ps1 と同じディレクトリに配置してください。" 'ERROR'
        throw "$StartImmichScriptName not found."
    }
    Write-Log "自動起動用スクリプトとして '$StartImmichScriptPath' を使用します。"

    # WSLのデフォルトユーザー名を取得
    $WSLDefaultUser = (wsl -d $Distro --exec whoami).Trim()
    if ([string]::IsNullOrEmpty($WSLDefaultUser)) {
        Write-Log "WSLのデフォルトユーザー名を取得できませんでした。WSLが正しくセットアップされているか確認してください。" 'ERROR'
        throw "WSL Default User acquisition failed."
    }
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
    $TaskArguments = "-ExecutionPolicy Bypass -NoProfile -File `"$StartImmichScriptPath`" -DistroName `"$Distro`" -WSLUserName `"$WSLDefaultUser`""
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