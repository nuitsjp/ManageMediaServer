. $PSScriptRoot\Common.ps1

function Set-ImmichPortProxy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$AppPort
    )
    Write-Log "ポートプロキシの構成を開始します..." -Level "INFO"
    $wslIp = ""
    try {
        $wslIp = (wsl -d $script:DistroName -- hostname -I).Split() |
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
