# 共通のログ関数
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    
    switch ($Level) {
        'INFO'  { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error $Message }
    }
}

function Set-PortProxyForImmich {
    param(
        [int]$AppPort,
        [string]$WslIp
    )
    $portProxyExists = netsh interface portproxy show v4tov4 | Select-String "0\.0\.0\.0\s+$AppPort\s+$WslIp\s+$AppPort"
    if ($portProxyExists) {
        Write-Log "既存のportproxy設定があります。"
    } else {
        $anyExistingProxy = netsh interface portproxy show v4tov4 | Select-String "0\.0\.0\.0\s+$AppPort\s+"
        if ($anyExistingProxy) {
            Write-Log "ポート $AppPort の既存portproxy設定を削除します。"
            netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$AppPort proto=tcp | Out-Null
        }
        Write-Log "portproxyを追加: 0.0.0.0:$AppPort → $($WslIp):$AppPort"
        netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$AppPort connectaddress=$WslIp connectport=$AppPort proto=tcp | Out-Null
    }
}

function Ensure-FirewallRuleForImmich {
    param(
        [int]$AppPort
    )
    $firewallRuleName = "Immich (WSL Port $AppPort)"
    if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
        Write-Log "Firewallルール '$firewallRuleName' を追加します。"
        New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -Action Allow `
                            -Protocol TCP -LocalPort $AppPort -Profile Any | Out-Null
    } else {
        Write-Log "既存のFirewallルール '$firewallRuleName' があります。"
    }
}