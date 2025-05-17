$script:DistroName = "Ubuntu"
$script:WSLUserName = "ubuntu"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','VERBOSE')][string]$Level = 'INFO'
    )
    switch ($Level.ToUpper()) {
        'INFO'    { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        'WARN'    { Write-Warning "[WARN] $Message" }
        'ERROR'   { Write-Error "[ERROR] $Message" }
        'VERBOSE' { Write-Verbose "[VERBOSE] $Message" }
    }
}

trap {
    Write-Log "エラー: $($_.Exception.Message)" -Level "ERROR"
    break
}

function Read-PasswordTwice {
    [CmdletBinding()]
    param (
        [string]$Prompt = "パスワードを入力してください "
    )
    while ($true) {
        $password1 = Read-Host -AsSecureString -Prompt $Prompt
        $password2 = Read-Host -AsSecureString -Prompt "もう一度パスワードを入力してください"
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1))
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2))
        if ($plain1 -eq $plain2) {
            Write-Log "パスワードが一致しました。" -Level "INFO"
            return $plain1
        } else {
            Write-Log "パスワードが一致しません。再度入力してください。" -Level "WARN"
        }
    }
}

function Test-WSLUserExists {
    [CmdletBinding()]
    param ()
    Write-Log "WSLディストリビューション '$script:DistroName' にユーザー '$script:WSLUserName' の存在確認を開始します。" -Level "INFO"
    $result = wsl -d $script:DistroName getent passwd $script:WSLUserName 2>$null
    if (-not [string]::IsNullOrEmpty($result)) {
        Write-Log "ユーザー '$script:WSLUserName' は存在します。" -Level "INFO"
        return $true
    } else {
        Write-Log "ユーザー '$script:WSLUserName' は存在しません。" -Level "INFO"
        return $false
    }
}

function Convert-WindowsPathToWSLPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath
    )
    # WindowsパスをWSLパスに変換
    $escapedPath = $WindowsPath.Replace('\', '\\')
    $cmd = "wsl -d $script:DistroName -- wslpath '$escapedPath'"
    $wslPath = (Invoke-Expression $cmd).Trim().Replace('"', '')
    Write-Log "Windowsパス: $WindowsPath" -Level 'VERBOSE'
    Write-Log "WSLパス: $wslPath" -Level 'VERBOSE'
    return $wslPath
}

function Set-ImmichPortProxy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro,
        [Parameter(Mandatory = $true)]
        [int]$AppPort
    )
    Write-Log "ポートプロキシの構成を開始します..." -Level "INFO"
    $wslIp = ""
    try {
        $wslIp = (wsl -d $Distro -- hostname -I).Split() |
                 Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } |
                 Select-Object -First 1
    } catch {
        Write-Log "WSL IPアドレスの取得に失敗しました。WSLが実行されているか確認してください。" -Level 'WARN'
    }
    if ($wslIp) {
        Write-Log "取得したWSL IPアドレス: $wslIp" -Level "INFO"
        $existingProxyInfo = netsh interface portproxy show v4tov4 | 
            Select-String "0\.0\.0\.0\s+$AppPort\s+(\d+\.\d+\.\d+\.\d+)\s+$AppPort"
        $needUpdate = $true
        if ($existingProxyInfo) {
            $existingIP = $existingProxyInfo.Matches.Groups[1].Value
            if ($existingIP -eq $wslIp) {
                Write-Log "既存のportproxy設定は現在のWSL IPアドレスと一致しています。更新は不要です。" -Level "INFO"
                $needUpdate = $false
            } else {
                Write-Log "既存のportproxy設定($existingIP)が現在のWSL IPアドレス($wslIp)と異なります。設定を更新します。" -Level "WARN"
                netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$AppPort proto=tcp | Out-Null
            }
        }
        if ($needUpdate) {
            Write-Log "portproxyを追加: 0.0.0.0:$AppPort -> $($wslIp):$AppPort" -Level "INFO"
            netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$AppPort connectaddress=$wslIp connectport=$AppPort proto=tcp | Out-Null
        }
    } else {
        Write-Log "WSL IPv4 の取得に失敗したため、port-proxy の構成をスキップしました。WSL内でImmichが起動しているか手動でご確認ください。" -Level "WARN"
    }
}

function Set-ImmichFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$AppPort
    )
    $firewallRuleName = "Immich (WSL Port $AppPort)"
    if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
        Write-Log "ファイアウォールルール '$firewallRuleName' を追加します..." -Level "INFO"
        New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -Action Allow `
                            -Protocol TCP -LocalPort $AppPort -Profile Any | Out-Null
    } else {
        Write-Log "既存のファイアウォールルール '$firewallRuleName' が見つかりました。" -Level "INFO"
    }
}

function Invoke-WSLCopyAndRunScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptFileName,
        [string[]]$Arguments = @()
    )
    # WSL内でスクリプトをコピー・変換・実行
    $ScriptPathOnWindows = Join-Path -Path $PSScriptRoot -ChildPath $ScriptFileName
    if (-not (Test-Path $ScriptPathOnWindows)) {
        throw "$ScriptPathOnWindows が見つかりません。PowerShellスクリプトと同じディレクトリに配置してください。"
    }
    $SourcePathOnWSL = Convert-WindowsPathToWSLPath -WindowsPath $ScriptPathOnWindows
    if ([string]::IsNullOrEmpty($SourcePathOnWSL)) {
        throw "WSLパスの変換結果が空です"
    }
    $DestinationScriptNameOnWSL = "setup_immich_for_distro.sh"
    $DestinationPathOnWSL = "/tmp/$DestinationScriptNameOnWSL"
    $ArgString = ($Arguments | ForEach-Object { "'$_'" }) -join " "
    $WslCommands = @"
cp '$SourcePathOnWSL' '$DestinationPathOnWSL' && \
dos2unix '$DestinationPathOnWSL' && \
chmod +x '$DestinationPathOnWSL' && \
sudo '$DestinationPathOnWSL' $ArgString
"@ -replace "`r",""
    Write-Log "WSL内で以下のコマンドを実行します:" -Level "VERBOSE"
    Write-Log $WslCommands -Level "VERBOSE"
    wsl -d $script:DistroName -- bash -c "$WslCommands"
    Write-Log "WSL内セットアップスクリプトの実行が完了しました。" -Level "INFO"
}

function Register-ImmichStartupTask {
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

function Test-ImmichComposeFileExists {
    [CmdletBinding()]
    param()
    Write-Log "/opt/immich/docker-compose.yml の存在を確認します..."
    wsl -d $script:DistroName -- test -f /opt/immich/docker-compose.yml
    if ($LASTEXITCODE -eq 0) {
        Write-Log "/opt/immich/docker-compose.yml が存在します。" -Level 'VERBOSE'
        return $true
    } else {
        Write-Log "/opt/immich/docker-compose.yml が存在しません。" -Level 'VERBOSE'
        return $false
    }
}

function Read-ImmichExternalLibraryPath {
    [CmdletBinding()]
    param(
        [string]$Prompt = "Immichの外部ライブラリーパスを入力してください: "
    )
    while ($true) {
        $inputPath = Read-Host -Prompt $Prompt
        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            Write-Log "パスが空です。再度入力してください。" -Level 'WARN'
            continue
        }
        if (Test-Path $inputPath) {
            Write-Log "パスが存在します: $inputPath" -Level 'INFO'
            return $inputPath
        } else {
            Write-Log "指定されたパスが存在しません: $inputPath" -Level 'WARN'
        }
    }
}