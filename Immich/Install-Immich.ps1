#!/usr/bin/env pwsh
#requires -RunAsAdministrator

# パラメーター定義・ログ設定・例外処理
Param(
    [int]   $AppPort  = 2283,
    [string]$TimeZone = 'Asia/Tokyo'
)

$ErrorActionPreference = 'Stop'
$Distro   = 'Ubuntu-24.04'

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
    Write-Log "予期せぬエラー: $_" 'ERROR'
    exit 1
}

# WSLディストリビューションの導入
if ((wsl -l -q) -notcontains $Distro) {
    Write-Log "$Distro ディストリビューションをインストールします。"
    wsl --install -d $Distro
    Write-Log "$Distro のインストールが完了しました。"
}

# WSL内セットアップスクリプトの実行
Write-Log "WSL内セットアップスクリプトを実行します。"

$WslSetupScriptName = "setup_immich_on_wsl.sh"
$WslSetupScriptPathOnWindows = Join-Path -Path $PSScriptRoot -ChildPath $WslSetupScriptName

try {
    $WslPathCmd = "wsl -d $Distro -- wslpath '$($WslSetupScriptPathOnWindows.Replace('\', '\\'))'"
    $SourcePathOnWSL = (Invoke-Expression $WslPathCmd).Trim().Replace('"', '')
    if ([string]::IsNullOrEmpty($SourcePathOnWSL)) {
        throw "WSLパスの変換結果が空です"
    }
} catch {
    Write-Log "WindowsパスからWSLパスへの変換に失敗しました。WSLや $Distro の状態を確認してください。" 'ERROR'
    Write-Log "エラー詳細: $($_.Exception.Message)"
    exit 1
}

$DestinationScriptNameOnWSL = "setup_immich_for_distro.sh"
$DestinationPathOnWSL = "/tmp/$DestinationScriptNameOnWSL"
$ImmichDirPath = "/opt/immich"

$WslCommands = @"
sudo apt-get update && sudo apt-get install -y dos2unix && \
cp '$SourcePathOnWSL' '$DestinationPathOnWSL' && \
dos2unix '$DestinationPathOnWSL' && \
chmod +x '$DestinationPathOnWSL' && \
'$DestinationPathOnWSL' '$TimeZone' '$ImmichDirPath'
"@ -replace "`r",""

try {
    wsl -d $Distro -- bash -c "$WslCommands"
    Write-Log "WSL内セットアップが完了しました。"
    Write-Log "Dockerグループの反映にはWSLの再起動または 'newgrp docker' の実行が必要な場合があります。"
} catch {
    Write-Log "WSL内セットアップスクリプト実行中にエラーが発生しました。" 'ERROR'
    Write-Log "エラー詳細: $($_.Exception.Message)"
    if ($_.Exception.ErrorRecord.TargetObject -is [System.Management.Automation.ErrorRecord]) {
        Write-Log "WSLからのエラー出力: $($_.Exception.ErrorRecord.TargetObject.Status)"
    }
    exit 1
}

# WSL対話セッション案内
Write-Host @"
=========== WSL対話セッション ===========
Immichのセットアップが完了しました。
WSLの対話セッションを開始します。

初回起動時やユーザー未設定時はパスワード設定等が必要です。
Dockerグループの反映には 'exit' で一度終了し再ログインするか、
'newgrp docker' を実行してください。

セットアップ確認や追加設定が終わったら 'exit' でWSLを終了してください。
======================================
"@ -ForegroundColor Cyan

Write-Log "WSL対話セッションを開始します。"
wsl -d $Distro

# LAN公開 (port-proxyとFirewall構成)
Write-Log "LAN公開用のport-proxyとFirewallを構成します。"

$wslIp = ""
try {
    $wslIp = (wsl -d $Distro -- hostname -I).Split() |
             Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
             Select-Object -First 1
} catch {
    Write-Log "WSL IPアドレスの取得に失敗しました。WSLが実行中か確認してください。" 'WARN'
}

if ($wslIp) {
    Write-Log "WSL IPアドレス: $wslIp"
    $existingRule = Get-NetFirewallPortFilter -Protocol TCP | Where-Object { $_.LocalPort -eq $AppPort }
    $portProxyExists = netsh interface portproxy show v4tov4 | Select-String "0\.0\.0\.0\s+$AppPort\s+$wslIp\s+$AppPort"

    if ($portProxyExists) {
        Write-Log "既存のportproxy設定があります。"
    } else {
        $anyExistingProxy = netsh interface portproxy show v4tov4 | Select-String "0\.0\.0\.0\s+$AppPort\s+"
        if ($anyExistingProxy) {
            Write-Log "ポート $AppPort の既存portproxy設定を削除します。"
            netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$AppPort proto=tcp | Out-Null
        }
        Write-Log "portproxyを追加: 0.0.0.0:$AppPort → $($wslIp):$AppPort"
        netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$AppPort connectaddress=$wslIp connectport=$AppPort proto=tcp | Out-Null
    }

    $firewallRuleName = "Immich (WSL Port $AppPort)"
    if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
        Write-Log "Firewallルール '$firewallRuleName' を追加します。"
        New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -Action Allow `
                            -Protocol TCP -LocalPort $AppPort -Profile Any | Out-Null
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
        Write-Log "$StartImmichScriptPath が見つかりません。" 'ERROR'
        throw "$StartImmichScriptName not found."
    }
    Write-Log "自動起動用スクリプト: '$StartImmichScriptPath'"

    $WSLDefaultUser = (wsl -d $Distro --exec whoami).Trim()
    if ([string]::IsNullOrEmpty($WSLDefaultUser)) {
        Write-Log "WSLのデフォルトユーザー名が取得できません。" 'ERROR'
        throw "WSL Default User acquisition failed."
    }
    Write-Log "WSL Default User: $WSLDefaultUser"

    $TaskName = "ImmichWSLAutoStart"
    $PwshPath = (Get-Command pwsh).Source
    if ([string]::IsNullOrEmpty($PwshPath)) {
        Write-Log "pwsh.exe が見つかりません。" 'ERROR'; throw "pwsh.exe not found."
    }

    $CurrentWindowsUserIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $CurrentWindowsUserName = $CurrentWindowsUserIdentity.Name
    Write-Log "タスク実行ユーザー: '$CurrentWindowsUserName'"

    $Principal = New-ScheduledTaskPrincipal `
                    -UserId $CurrentWindowsUserName `
                    -LogonType S4U `
                    -RunLevel Highest

    $TaskDescription = "WSL($Distro)とImmichサービスをWindows起動時に自動起動します。"
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
    Write-Log "自動起動設定中にエラー: $($_.Exception.Message)" 'ERROR'
    Write-Log "  コマンドレット: $($_.TargetObject)" 'ERROR'
    Write-Log "管理者権限やユーザー設定を確認してください。" 'WARN'
}

Write-Log "Install-Immich.ps1 の処理が完了しました。"