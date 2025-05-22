#Requires -RunAsAdministrator

<#
.SYNOPSIS
    WSL2のインストールと設定を自動化するスクリプト

.DESCRIPTION
    このスクリプトは以下の処理を実行します：
    - WSL (Windows Subsystem for Linux) 機能の有効化
    - Virtual Machine Platform 機能の有効化
    - WSL2をデフォルトバージョンとして設定
    冪等性が担保されており、既に設定済みの項目はスキップされます。

.EXAMPLE
    .\Install-Wsl.ps1
#>

[CmdletBinding()]
param()

# ログ出力関数
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARN" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}

# Windows機能の状態をチェックする関数
function Test-WindowsFeature {
    param([string]$FeatureName)
    
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        return $feature.State -eq "Enabled"
    }
    catch {
        Write-Log "機能 '$FeatureName' の状態チェックに失敗しました: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# WSLのバージョンをチェックする関数
function Test-WslDefaultVersion {
    try {
        $wslOutput = wsl --status 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $wslOutput -match "既定のバージョン:\s*2" -or $wslOutput -match "Default Version:\s*2"
        }
        return $false
    }
    catch {
        return $false
    }
}

# メイン処理開始
Write-Log "WSL2セットアップスクリプトを開始します"

# 管理者権限チェック
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Log "このスクリプトは管理者権限で実行する必要があります" "ERROR"
    exit 1
}

$needsReboot = $false
$featuresEnabled = $false

# WSL機能の有効化チェック
Write-Log "WSL機能の状態をチェックしています..."
if (Test-WindowsFeature -FeatureName "Microsoft-Windows-Subsystem-Linux") {
    Write-Log "WSL機能は既に有効化されています" "SUCCESS"
} else {
    Write-Log "WSL機能を有効化しています..."
    try {
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
        if ($LASTEXITCODE -eq 0) {
            Write-Log "WSL機能の有効化が完了しました" "SUCCESS"
            $needsReboot = $true
            $featuresEnabled = $true
        } else {
            Write-Log "WSL機能の有効化に失敗しました (Exit Code: $LASTEXITCODE)" "ERROR"
            exit 1
        }
    }
    catch {
        Write-Log "WSL機能の有効化中にエラーが発生しました: $($_.Exception.Message)" "ERROR"
        exit 1
    }
}

# Virtual Machine Platform機能の有効化チェック
Write-Log "Virtual Machine Platform機能の状態をチェックしています..."
if (Test-WindowsFeature -FeatureName "VirtualMachinePlatform") {
    Write-Log "Virtual Machine Platform機能は既に有効化されています" "SUCCESS"
} else {
    Write-Log "Virtual Machine Platform機能を有効化しています..."
    try {
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Virtual Machine Platform機能の有効化が完了しました" "SUCCESS"
            $needsReboot = $true
            $featuresEnabled = $true
        } else {
            Write-Log "Virtual Machine Platform機能の有効化に失敗しました (Exit Code: $LASTEXITCODE)" "ERROR"
            exit 1
        }
    }
    catch {
        Write-Log "Virtual Machine Platform機能の有効化中にエラーが発生しました: $($_.Exception.Message)" "ERROR"
        exit 1
    }
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
Write-Log "WSLのデフォルトバージョンをチェックしています..."
if (Test-WslDefaultVersion) {
    Write-Log "WSL2は既にデフォルトバージョンとして設定されています" "SUCCESS"
} else {
    Write-Log "WSL2をデフォルトバージョンとして設定しています..."
    try {
        wsl --set-default-version 2
        if ($LASTEXITCODE -eq 0) {
            Write-Log "WSL2がデフォルトバージョンとして設定されました" "SUCCESS"
        } else {
            Write-Log "WSL2のデフォルトバージョン設定に失敗しました (Exit Code: $LASTEXITCODE)" "WARN"
            Write-Log "手動で 'wsl --set-default-version 2' を実行してください" "WARN"
        }
    }
    catch {
        Write-Log "WSL2のデフォルトバージョン設定中にエラーが発生しました: $($_.Exception.Message)" "WARN"
        Write-Log "手動で 'wsl --set-default-version 2' を実行してください" "WARN"
    }
}

# WSLカーネル更新プログラムの確認
Write-Log "WSLカーネル更新プログラムの確認を行います..."
Write-Log "最新のWSLカーネル更新プログラムを以下からダウンロードしてインストールしてください：" "WARN"
Write-Log "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi" "WARN"

Write-Log "WSL2のセットアップが完了しました" "SUCCESS"
Write-Log "次のステップ: Ubuntu 22.04 LTSのインストール" "INFO"
Write-Log "コマンド: wsl --install -d Ubuntu-22.04" "INFO"
