#!/usr/bin/env pwsh
#requires -RunAsAdministrator

[CmdletBinding()]
Param(
    [int]   $AppPort  = 2283,
    [string]$TimeZone = 'Asia/Tokyo'
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\Modules\Functions.ps1

trap {
    Write-Error $_.Exception.ToString()
    exit 1
}

# WSLディストロ導入とユーザー作成
$UserPassword = ''
$ImmichExternalLibraryPath = ''
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

# パッケージ更新前に /opt/immich/docker-compose.yml の存在チェックして、外部ライブラリパスを取得
if (-not (Test-ImmichComposeFileExists)) {
    $ImmichExternalLibraryPath = Read-ImmichExternalLibraryPath
}

# パッケージ更新とdos2unixインストール
Write-Log "パッケージの更新と、dos2unixのインストールをしています..."
wsl -d $script:DistroName -- bash -c "sudo apt-get update && sudo apt-get install -y dos2unix"

# WSL内セットアップスクリプト実行
Write-Log "WSL内セットアップスクリプトの準備と実行..."
Invoke-WSLCopyAndRunScript -ScriptFileName "setup_immich_on_wsl.sh" -Arguments @($TimeZone, $UserPassword, $ImmichExternalLibraryPath)

# ポートプロキシとファイアウォール設定
Set-ImmichPortProxy -AppPort $AppPort
Set-ImmichFirewallRule -AppPort $AppPort

# タスクスケジューラー登録
Write-Log "Windows起動時のImmich自動起動を設定します..."
$StartImmichScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Start-Immich.ps1"
Register-ImmichStartupTask -StartImmichScriptPath $StartImmichScriptPath

# インストール後にImmichを自動的に起動
Write-Log "Immichを起動しています..."
& "$StartImmichScriptPath"
if ($LASTEXITCODE -ne 0) {
    throw "Immichの起動に失敗しました。終了コード: $LASTEXITCODE"
}

Write-Log "Install-Immich.ps1 の処理が完了しました。"