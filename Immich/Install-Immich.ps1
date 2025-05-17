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
$UserPassword = ''
if ((wsl -l -q) -notcontains $script:DistroName) {
    Write-Log "WSLディストリビューション '$script:DistroName' にユーザー '$script:WSLUserName' を作成します。"
    $UserPassword = Read-PasswordTwice
    Write-Log "$script:DistroName ディストロを導入 …"
    wsl --install -d $script:DistroName
}
elseif (-not (Test-WSLUserExists)) {
    Write-Log "WSLディストリビューション '$script:DistroName' にユーザー '$script:WSLUserName' が存在しません。新規作成します。"
    $UserPassword = Read-PasswordTwice
}

Write-Log "パッケージの更新と、dos2unixのインストールをしています..."
wsl -d $script:DistroName -- bash -c "sudo apt-get update && sudo apt-get install -y dos2unix"

# --- 3- WSL内セットアップスクリプトの実行 ------------------------------------
Write-Log "WSL内セットアップスクリプトの準備と実行..."
Invoke-WSLCopyAndRunScript -ScriptFileName "setup_immich_on_wsl.sh" -Arguments @($TimeZone, $UserPassword)

# --- 7- Windows起動時のImmich自動起動設定 (Task Scheduler) ---
Write-Log "Windows起動時のImmich自動起動を設定します..."

$StartImmichScriptName = "Start-Immich.ps1"
$StartImmichScriptPath = Join-Path -Path $PSScriptRoot -ChildPath $StartImmichScriptName

Register-ImmichStartupTask -StartImmichScriptPath $StartImmichScriptPath

# --- (既存のスクリプトの最終的な完了メッセージやexitの前にこのセクションを配置) ---
Write-Log "Install-Immich.ps1 の処理が完了しました。"