#!/usr/bin/env pwsh

# 共通の定数設定
$script:Distro = 'Ubuntu-24.04'
$script:AppPort = 2283
$script:TimeZone = 'Asia/Tokyo'
$script:ImmichDir = Join-Path $PSScriptRoot 'instance'

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

# WSLのパス変換関数
function ConvertTo-WslPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath,
        
        [Parameter(Mandatory = $false)]
        [string]$DistributionName = $script:Distro
    )
    
    $wslPathCmd = "wsl -d $DistributionName -- wslpath '$($WindowsPath.Replace('\', '\\'))'"
    $wslPath = (Invoke-Expression $wslPathCmd).Trim()
    
    if ([string]::IsNullOrEmpty($wslPath)) {
        Write-Error "WindowsパスからWSLパスへの変換に失敗しました。WSLや $DistributionName の状態を確認してください。"
        return $null
    }
    
    return $wslPath
}

# Docker Composeのバージョン確認用関数
function Get-DockerComposeCommand {
    param (
        [Parameter(Mandatory = $false)]
        [string]$DistributionName = $script:Distro
    )
    
    # Docker Composeのバージョンを確認（新形式か旧形式か）
    & wsl -d $DistributionName -- docker compose version >$null 2>&1
    $useNewCompose = $LASTEXITCODE -eq 0
    
    # PowerShell 7以上では if ステートメントを使わずに三項演算子のように書けるが
    # 古いPowerShellとの互換性のために従来の書き方を使用
    if ($useNewCompose) {
        return "docker compose"
    } else {
        return "docker-compose"
    }
}

# WSLに特定のディストリビューションが存在するか確認する関数
function Test-WslDistribution {
    param (
        [Parameter(Mandatory = $false)]
        [string]$DistributionName = $script:Distro
    )
    
    return (wsl -l -q) -contains $DistributionName
}

# Immichのディレクトリが存在するか確認する関数
function Test-ImmichDirectory {
    param (
        [Parameter(Mandatory = $false)]
        [string]$DirectoryPath = $script:ImmichDir
    )
    
    if (-not (Test-Path $DirectoryPath)) {
        Write-Log "Immich実行ディレクトリが見つかりません: $DirectoryPath" -Level ERROR
        return $false
    }
    
    return $true
}