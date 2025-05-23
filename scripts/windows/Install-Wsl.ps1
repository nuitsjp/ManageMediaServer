#Requires -RunAsAdministrator

<#
.SYNOPSIS
    WSL2のインストールと設定を自動化するスクリプト

.DESCRIPTION
    WSL機能の有効化、WSL2の設定、Ubuntu LTSのインストールを自動実行します。
    冪等性が担保されており、既に設定済みの項目はスキップされます。

.PARAMETER SkipUbuntuInstall
    Ubuntuのインストールをスキップします

.PARAMETER UbuntuDistro
    インストールするUbuntuディストリビューション名（デフォルト: Ubuntu-24.04）

.EXAMPLE
    .\Install-Wsl.ps1

.EXAMPLE
    .\Install-Wsl.ps1 -SkipUbuntuInstall

.EXAMPLE
    .\Install-Wsl.ps1 -UbuntuDistro "Ubuntu-22.04"
#>

[CmdletBinding()]
param(
    [switch]$SkipUbuntuInstall,
    [string]$UbuntuDistro = "Ubuntu-24.04"
)

# エラーハンドリング設定
$ErrorActionPreference = "Stop"
trap {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[ERROR] 行: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    exit 1
}

# 設定変数
$UBUNTU_DISTRO_NAME = $UbuntuDistro
$UBUNTU_DISPLAY_NAME = $UbuntuDistro -replace "-", " "

# ログ出力関数
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$timestamp] $Message" -ForegroundColor $color
}

# Windows機能有効化関数
function Enable-WindowsFeature {
    param([string]$FeatureName, [string]$DisplayName)
    
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName
    if ($feature.State -eq "Enabled") {

        Write-Log "$DisplayName は既に有効化されています" "SUCCESS"
        return $false
    }
    
    Write-Log "$DisplayName を有効化しています..."
    dism.exe /online /enable-feature /featurename:$FeatureName /all /norestart
    if ($LASTEXITCODE -ne 0) {
        throw "$DisplayName の有効化に失敗しました (Exit Code: $LASTEXITCODE)"
    }
    Write-Log "$DisplayName の有効化が完了しました" "SUCCESS"
    return $true
}

# Ubuntu確認関数（文字エンコーディング対応）
function Test-UbuntuInstalled {
    # wsl --list の出力をプレーンテキストで取得
    $wslList = wsl --list 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    
    # 文字列の正規化と複数の方法でチェック
    $normalizedOutput = $wslList -replace '[^\x20-\x7E]', '' # 非ASCII文字を除去
    $distroFound = $normalizedOutput -match [regex]::Escape($UBUNTU_DISTRO_NAME) -or 
                  $normalizedOutput -match "Ubuntu" -or
                  $wslList.Contains($UBUNTU_DISTRO_NAME) -or
                  $wslList.Contains("Ubuntu")
    
    return $distroFound
}

# Ubuntu動作確認関数
function Test-UbuntuRunning {
    wsl -d $UBUNTU_DISTRO_NAME --exec echo "test" *>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

# メイン処理開始
Write-Log "WSL2セットアップスクリプトを開始します"

# 管理者権限チェック
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    throw "このスクリプトは管理者権限で実行する必要があります"
}

$needsReboot = $false

# WSL機能の有効化
Write-Log "WSL機能の状態をチェックしています..."
if (Enable-WindowsFeature -FeatureName "Microsoft-Windows-Subsystem-Linux" -DisplayName "WSL機能") {
    $needsReboot = $true
}

# Virtual Machine Platform機能の有効化
Write-Log "Virtual Machine Platform機能の状態をチェックしています..."
if (Enable-WindowsFeature -FeatureName "VirtualMachinePlatform" -DisplayName "Virtual Machine Platform機能") {
    $needsReboot = $true
}

# 再起動が必要な場合の処理
if ($needsReboot) {
    Write-Log "機能の有効化が完了しました。システムの再起動が必要です" "WARN"
    Write-Log "再起動後、再度このスクリプトを実行してWSL2の設定を完了してください" "WARN"
    
    $response = Read-Host "今すぐ再起動しますか？ (y/N)"
    if ($response -eq "y" -or $response -eq "Y") {
        Write-Log "システムを再起動しています..."
        Restart-Computer -Force
    } else {
        Write-Log "手動で再起動を行い、その後再度スクリプトを実行してください" "WARN"
        exit 0
    }
}

# WSL2のデフォルトバージョン設定
Write-Log "WSL2をデフォルトバージョンとして設定しています..."
wsl --set-default-version 2
if ($LASTEXITCODE -ne 0) {
    Write-Log "WSL2のデフォルトバージョン設定に失敗しました。手動で実行してください: wsl --set-default-version 2" "WARN"
}

# WSLカーネル更新プログラムの案内
Write-Log "WSLカーネル更新プログラムを以下からダウンロードしてインストールしてください：" "WARN"
Write-Log "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi" "WARN"

# Ubuntu 24.04 LTSのインストール
if (-not $SkipUbuntuInstall) {
    Write-Log "$UBUNTU_DISPLAY_NAME のインストール状況をチェックしています..."
    
    if (Test-UbuntuInstalled) {
        Write-Log "$UBUNTU_DISPLAY_NAME は既にインストールされています" "SUCCESS"
        
        # 動作確認
        if (Test-UbuntuRunning) {
            Write-Log "$UBUNTU_DISPLAY_NAME は正常に動作しています" "SUCCESS"
        } else {
            Write-Log "$UBUNTU_DISPLAY_NAME の初期設定が必要です。手動で完了してください: wsl -d $UBUNTU_DISTRO_NAME" "WARN"
        }
    } else {
        Write-Log "$UBUNTU_DISPLAY_NAME をインストールしています..." 
        Write-Log "インストール中にユーザー名とパスワードの入力が求められます" "INFO"
        
        # Ubuntuのインストール実行
        wsl --install -d $UBUNTU_DISTRO_NAME
        
        if ($LASTEXITCODE -eq 0) {
            Write-Log "$UBUNTU_DISPLAY_NAME のインストールが開始されました" "SUCCESS"
            
            # 短時間の待機（2分）
            Write-Log "初期設定の完了を待機中..."
            $timeout = 120
            $elapsed = 0
            
            while ($elapsed -lt $timeout -and -not (Test-UbuntuRunning)) {
                Start-Sleep -Seconds 10
                $elapsed += 10
            }
            
            if (Test-UbuntuRunning) {
                Write-Log "$UBUNTU_DISPLAY_NAME の初期設定が完了しました" "SUCCESS"
            } else {
                Write-Log "初期設定の完了を確認できませんでした。手動で確認してください: wsl -d $UBUNTU_DISTRO_NAME" "WARN"
            }
        } else {
            Write-Log "$UBUNTU_DISPLAY_NAME のインストールに失敗しました。手動で実行してください: wsl --install -d $UBUNTU_DISTRO_NAME" "WARN"
        }
    }
} else {
    Write-Log "$UBUNTU_DISPLAY_NAME のインストールをスキップしました" "INFO"
}

Write-Log "WSL2のセットアップが完了しました" "SUCCESS"
