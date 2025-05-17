function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','Verbose')][string]$Level = 'INFO'
    )
    switch ($Level) {
        'INFO'    { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        'WARN'    { Write-Warning $Message }
        'ERROR'   { Write-Error $Message }
        'Verbose' { Write-Verbose $Message }
    }
}

function Read-PasswordTwice {
    param (
        [string]$Prompt = "パスワードを入力してください "
    )
    while ($true) {
        $password1 = Read-Host -AsSecureString -Prompt $Prompt
        $password2 = Read-Host -AsSecureString -Prompt "もう一度パスワードを入力してください"
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1))
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2))
        if ($plain1 -eq $plain2) {
            return $plain1
        } else {
            Write-Host "パスワードが一致しません。再度入力してください。" -ForegroundColor Yellow
        }
    }
}

function Test-WSLUserExists {
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [string]$Distro = "Ubuntu"
    )
    Write-Log -Message "WSLディストリビューション '$Distro' にユーザー '$UserName' が存在するか確認します。" -Level "INFO"
    $result = wsl -d $Distro getent passwd $UserName 2>$null
    if (-not [string]::IsNullOrEmpty($result)) {
        Write-Log -Message "ユーザー '$UserName' は存在します。" -Level "INFO"
        return $true
    } else {
        Write-Log -Message "ユーザー '$UserName' は存在しません。" -Level "INFO"
        return $false
    }
}

function Convert-WindowsPathToWSLPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath,
        [string]$Distro = "Ubuntu"
    )
    # パスのバックスラッシュをエスケープ
    $escapedPath = $WindowsPath.Replace('\', '\\')
    $cmd = "wsl -d $Distro -- wslpath '$escapedPath'"
    $wslPath = (Invoke-Expression $cmd).Trim().Replace('"', '')
    return $wslPath
}

function Set-ImmichPortProxyAndFirewall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro,
        [Parameter(Mandatory = $true)]
        [int]$AppPort
    )
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
        
        # まず、このポートに対する既存のportproxy設定を確認
        $existingProxyInfo = netsh interface portproxy show v4tov4 | 
            Select-String "0\.0\.0\.0\s+$AppPort\s+(\d+\.\d+\.\d+\.\d+)\s+$AppPort"
        
        $needUpdate = $true
        if ($existingProxyInfo) {
            # 既存設定から現在のターゲットIPを取得
            $existingIP = $existingProxyInfo.Matches.Groups[1].Value
            if ($existingIP -eq $wslIp) {
                Write-Log "既存のportproxy設定が現在のWSL IPアドレスと一致しています。更新不要。"
                $needUpdate = $false
            } else {
                Write-Log "ポート $AppPort に対する既存のportproxy設定($existingIP)が現在のWSL IPアドレス($wslIp)と異なります。更新します。"
                # 異なるIPへの既存設定を削除
                netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$AppPort proto=tcp | Out-Null
            }
        }
        
        # 設定が必要な場合は追加
        if ($needUpdate) {
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
}