<#
.SYNOPSIS
    Enable WSL2 “mirrored” networking mode (Windows 11 22H2/23H2+).

.DESCRIPTION
    • Creates/updates `%USERPROFILE%\.wslconfig`
    • Adds   networkingMode = mirrored
    • (Opt) dnsTunneling = true / autoProxy = true
    • Shuts down WSL so the change takes effect immediately.

.PARAMETER EnableDnsTunneling
    Add 'dnsTunneling=true'  (better VPN compatibility).

.PARAMETER EnableAutoProxy
    Add 'autoProxy=true'     (inherit Windows proxy settings).

.EXAMPLE
    ./Enable-WSLMirrored.ps1 -EnableDnsTunneling -EnableAutoProxy
#>

[CmdletBinding()]
param (
    [switch]$EnableDnsTunneling,
    [switch]$EnableAutoProxy
)

#-- 2) Prepare .wslconfig content -------------------------------------------
$cfgPath = Join-Path $HOME '.wslconfig'
if (Test-Path $cfgPath) {
    Copy-Item $cfgPath "$cfgPath.bak" -Force
    Write-Verbose "Backup created: $cfgPath.bak"
}

$cfgLines = @('[wsl2]', 'networkingMode=mirrored')
if ($EnableDnsTunneling) { $cfgLines += 'dnsTunneling=true' }
if ($EnableAutoProxy)   { $cfgLines += 'autoProxy=true'   }

Set-Content -Path $cfgPath -Value $cfgLines -Encoding UTF8
Write-Host ".wslconfig updated at $cfgPath" -ForegroundColor Green

#-- 3) Offer to shut down WSL immediately ------------------------------------
$distrosRunning = (wsl.exe -q --running) -ne ''
if ($distrosRunning) {
    $yes = Read-Host "WSL is running. Shut it down now to apply mirrored networking? [y/N]"
    if ($yes -match '^[Yy]') {
        wsl.exe --shutdown
        Write-Host "WSL has been shut down. Next launch will use mirrored networking."
    } else {
        Write-Host "Skip shutdown. Re-launch WSL later for changes to take effect."
    }
} else {
    Write-Host "No active WSL instances. Next launch will use mirrored networking."
}

#-- 4) Reminder --------------------------------------------------------------
Write-Host "`nDone!  After WSL restarts, LAN 端末からは http://<Windows_IP>:PORT で直接アクセスできます。"
