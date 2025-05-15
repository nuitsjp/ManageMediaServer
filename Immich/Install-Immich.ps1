#!/usr/bin/env pwsh
#requires -RunAsAdministrator

# パラメーター定義・ログ設定・例外処理
Param(
    [int]   $AppPort  = 2283,
    [string]$TimeZone = 'Asia/Tokyo'
)

$ErrorActionPreference = 'Stop'

# Functionsファイルの読み込み
. $PSScriptRoot\Functions.ps1

# パラメータが指定された場合は共通変数を上書き
if ($AppPort -ne $script:AppPort) {
    $script:AppPort = $AppPort
}

if ($TimeZone -ne $script:TimeZone) {
    $script:TimeZone = $TimeZone
}

trap {
    Write-Log "予期せぬエラー: $_" -Level ERROR
    exit 1
}

# ユーザー情報の収集
$WSLUserName = "ubuntu"
Write-Log "ユーザー名は '$WSLUserName' で固定されています。"

# ディストリの有無を判定
$needPassword = $false
if (-not (Test-WslDistribution)) {
    # ディストリ未インストール → パスワード必須
    $needPassword = $true
} else {
    # ディストリが存在する場合、ubuntuユーザーの有無をWSL内で確認
    $userExists = $false
    try {
        $userId = wsl -d $script:Distro -- id -u $WSLUserName 2>$null
        $userExists = $null -ne $userId -and $userId -match '^\d+$'
    } catch {
        $userExists = $false
    }
    if (-not $userExists) {
        $needPassword = $true
    }
}

if ($needPassword) {
    # パスワード入力・確認ループを関数で実施
    $WSLPassword = Read-PasswordWithConfirmation
    Write-Log "パスワードの入力が完了しました。"
} else {
    $WSLPassword = ""
    Write-Log "既存のubuntuユーザーが存在するため、パスワード入力はスキップします。"
}

Write-Log "ユーザー情報の入力が完了しました。WSLのセットアップを開始します。"

# WSLディストリビューションの導入
if (-not (Test-WslDistribution)) {
    Write-Log "$script:Distro ディストリビューションをインストールします。"
    wsl --install -d $script:Distro
    Write-Log "$script:Distro のインストールが完了しました。"
    
    # WSLが起動するまで待機
    Write-Log "WSLの起動を待機しています..."
    $retryCount = 0
    $maxRetries = 10
    $success = $false
    
    while (-not $success -and $retryCount -lt $maxRetries) {
        try {
            Start-Sleep -Seconds 2
            $result = wsl -d $script:Distro -- echo "WSL is ready"
            if ($result -eq "WSL is ready") {
                $success = $true
                Write-Log "WSLが正常に起動しました。"
            }
        } catch {
            $retryCount++
            Write-Log "WSLの起動を待機中... ($retryCount/$maxRetries)"
        }
    }
    
    if (-not $success) {
        Write-Log "WSLの起動を確認できませんでした。処理を中断します。" -Level ERROR
        exit 1
    }
}

# WSL内セットアップスクリプトの実行
Write-Log "WSL内セットアップスクリプトを実行します。"

$WslSetupScriptName = "setup_immich_on_wsl.sh"
$WslSetupScriptPathOnWindows = Join-Path -Path $PSScriptRoot -ChildPath $WslSetupScriptName

try {
    $SourcePathOnWSL = ConvertTo-WslPath -WindowsPath $WslSetupScriptPathOnWindows
    if ([string]::IsNullOrEmpty($SourcePathOnWSL)) {
        throw "WSLパスの変換結果が空です"
    }
} catch {
    Write-Log "WindowsパスからWSLパスへの変換に失敗しました。WSLや $script:Distro の状態を確認してください。" -Level ERROR
    Write-Log "エラー詳細: $($_.Exception.Message)" -Level ERROR
    exit 1
}

$DestinationScriptNameOnWSL = "setup_immich_for_distro.sh"
$DestinationPathOnWSL = "/tmp/$DestinationScriptNameOnWSL"
$ImmichDirPath = "/opt/immich"

# セットアップスクリプトの準備と実行
$PrepareScriptCommands = @"
sudo apt-get update && sudo apt-get install -y dos2unix && \
cp '$SourcePathOnWSL' '$DestinationPathOnWSL' && \
dos2unix '$DestinationPathOnWSL' && \
chmod +x '$DestinationPathOnWSL'
"@ -replace "`r",""

try {
    Write-Log "セットアップスクリプトを準備しています..."
    wsl -d $script:Distro -- bash -c "sudo $PrepareScriptCommands"
    
    # ユーザー名とパスワードを引数として渡す
    Write-Log "ユーザー '$WSLUserName' の設定とImmichのセットアップを実行しています..."
    # シングルクォートで囲み、シェルによる特殊文字の解釈を防止
    $escapedPassword = $WSLPassword.Replace("'", "'\''")  # シングルクォートをエスケープ
    wsl -d $script:Distro -- bash -c "sudo '$DestinationPathOnWSL' '$script:TimeZone' '$ImmichDirPath' '$escapedPassword'"
    
    Write-Log "WSL内セットアップが完了しました。"
    Write-Log "WSLを再起動してユーザー設定とDockerグループの変更を適用します..."
    
    # WSLを再起動して設定を適用
    wsl --terminate $script:Distro
    Start-Sleep -Seconds 3
    wsl -d $script:Distro -- echo "WSL restarted"
    
    # 現在のデフォルトユーザーを確認
    $currentUser = (wsl -d $script:Distro -- whoami).Trim()
    Write-Log "現在のWSLデフォルトユーザー: $currentUser"
    
    if ($currentUser -ne $WSLUserName) {
        Write-Log "WSLのデフォルトユーザーが '$WSLUserName' に設定されていません。手動で確認してください。" -Level WARN
    } else {
        Write-Log "WSLのデフォルトユーザーが正常に '$WSLUserName' に設定されました。"
    }
    
} catch {
    Write-Log "WSL内セットアップスクリプト実行中にエラーが発生しました。" -Level ERROR
    Write-Log "エラー詳細: $($_.Exception.Message)" -Level ERROR
    if ($_.Exception.ErrorRecord.TargetObject -is [System.Management.Automation.ErrorRecord]) {
        Write-Log "WSLからのエラー出力: $($_.Exception.ErrorRecord.TargetObject.Status)" -Level ERROR
    }
    exit 1
}

# LAN公開 (port-proxyとFirewall構成)
Write-Log "LAN公開用のport-proxyとFirewallを構成します。"

$wslIp = ""
try {
    $wslIp = (wsl -d $script:Distro -- hostname -I).Split() |
             Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
             Select-Object -First 1
} catch {
    Write-Log "WSL IPアドレスの取得に失敗しました。WSLが実行中か確認してください。" -Level WARN
}

if ($wslIp) {
    Write-Log "WSL IPアドレス: $wslIp"
    $existingRule = Get-NetFirewallPortFilter -Protocol TCP | Where-Object { $_.LocalPort -eq $script:AppPort }
    $portProxyExists = netsh interface portproxy show v4tov4 | Select-String "0\.0\.0\.0\s+$($script:AppPort)\s+$wslIp\s+$($script:AppPort)"

    if ($portProxyExists) {
        Write-Log "既存のportproxy設定があります。"
    } else {
        $anyExistingProxy = netsh interface portproxy show v4tov4 | Select-String "0\.0\.0\.0\s+$($script:AppPort)\s+"
        if ($anyExistingProxy) {
            Write-Log "ポート $($script:AppPort) の既存portproxy設定を削除します。"
            netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$script:AppPort proto=tcp | Out-Null
        }
        Write-Log "portproxyを追加: 0.0.0.0:$($script:AppPort) → $($wslIp):$($script:AppPort)"
        netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$script:AppPort connectaddress=$wslIp connectport=$script:AppPort proto=tcp | Out-Null
    }

    $firewallRuleName = "Immich (WSL Port $($script:AppPort))"
    if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
        Write-Log "Firewallルール '$firewallRuleName' を追加します。"
        New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -Action Allow `
                            -Protocol TCP -LocalPort $script:AppPort -Profile Any | Out-Null
    } else {
        Write-Log "既存のFirewallルール '$firewallRuleName' があります。"
    }

} else {
    Write-Warning "WSL IPv4が取得できず、port-proxyとFirewallの構成をスキップしました。"
}

# Windows起動時のImmich自動起動設定
Write-Log "Windows起動時のImmich自動起動を設定します。"

try {
    $StartImmichScriptName = "Start-Immich.ps1"
    $StartImmichScriptPath = Join-Path -Path $PSScriptRoot -ChildPath $StartImmichScriptName

    if (-not (Test-Path $StartImmichScriptPath)) {
        Write-Log "$StartImmichScriptPath が見つかりません。" -Level ERROR
        throw "$StartImmichScriptName not found."
    }
    Write-Log "自動起動用スクリプト: '$StartImmichScriptPath'"

    $WSLDefaultUser = $WSLUserName  # 設定したユーザー名を使用
    Write-Log "WSL Default User: $WSLDefaultUser"

    $TaskName = "ImmichWSLAutoStart"
    $PwshPath = (Get-Command pwsh).Source
    if ([string]::IsNullOrEmpty($PwshPath)) {
        Write-Log "pwsh.exe が見つかりません。" -Level ERROR; throw "pwsh.exe not found."
    }

    $CurrentWindowsUserIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $CurrentWindowsUserName = $CurrentWindowsUserIdentity.Name
    Write-Log "タスク実行ユーザー: '$CurrentWindowsUserName'"

    $Principal = New-ScheduledTaskPrincipal `
                    -UserId $CurrentWindowsUserName `
                    -LogonType S4U `
                    -RunLevel Highest

    $TaskDescription = "WSL($script:Distro)とImmichサービスをWindows起動時に自動起動します。"
    $TaskArguments = "-ExecutionPolicy Bypass -NoProfile -File `"$StartImmichScriptPath`" -WSLUserName `"$WSLDefaultUser`""
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

    Write-Log "既存のタスク '$TaskName' を削除します。"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    Write-Log "タスク '$TaskName' を登録します。"
    Register-ScheduledTask `
        -TaskName    $TaskName `
        -Action      $Action `
        -Trigger     $Trigger `
        -Principal   $Principal `
        -Settings    $Settings `
        -Description $TaskDescription `
        -ErrorAction Stop | Out-Null

    Write-Log "タスク '$TaskName' を登録しました。"

} catch {
    Write-Log "自動起動設定中にエラー: $($_.Exception.Message)" -Level ERROR
    Write-Log "  コマンドレット: $($_.TargetObject)" -Level ERROR
    Write-Log "管理者権限やユーザー設定を確認してください。" -Level WARN
}

Write-Log "セットアップが完了しました。以下のURLでImmichにアクセスできます。"
Write-Log "http://localhost:$script:AppPort" -Level INFO
Write-Log "Install-Immich.ps1 の処理が完了しました。"