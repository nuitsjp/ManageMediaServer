#Requires -RunAsAdministrator

<#
.SYNOPSIS
    WSL2のインストールと設定を自動化するスクリプト

.DESCRIPTION
    このスクリプトは以下の処理を実行します：
    - WSL (Windows Subsystem for Linux) 機能の有効化
    - Virtual Machine Platform 機能の有効化
    - WSL2をデフォルトバージョンとして設定
    - Ubuntu 24.04 LTSのインストール
    - 初期ユーザー設定とsudo権限確認
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

# 設定変数
$UBUNTU_DISTRO_NAME = $UbuntuDistro
$UBUNTU_DISPLAY_NAME = $UbuntuDistro -replace "-", " "

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

# Ubuntuディストリビューションの確認関数
function Test-UbuntuInstalled {
    try {
        # wsl --list の出力をプレーンテキストで取得
        $wslList = wsl --list 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            # 文字列の正規化と複数の方法でチェック
            $normalizedOutput = $wslList -replace '[^\x20-\x7E]', '' # 非ASCII文字を除去
            $distroFound = $normalizedOutput -match [regex]::Escape($UBUNTU_DISTRO_NAME) -or 
                          $normalizedOutput -match "Ubuntu" -or
                          $wslList.Contains($UBUNTU_DISTRO_NAME) -or
                          $wslList.Contains("Ubuntu")
            
            Write-Log "WSL一覧出力: $($normalizedOutput -replace '\s+', ' ')" "DEBUG"
            Write-Log "ディストリビューション検索結果: $distroFound" "DEBUG"
            
            return $distroFound
        }
        return $false
    }
    catch {
        Write-Log "Test-UbuntuInstalled でエラーが発生しました: $($_.Exception.Message)" "DEBUG"
        return $false
    }
}

# Ubuntuの動作確認関数
function Test-UbuntuRunning {
    param([string]$DistroName = $UBUNTU_DISTRO_NAME)
    
    try {
        $result = wsl -d $DistroName --exec echo "test" 2>&1
        return $LASTEXITCODE -eq 0
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

# Ubuntu 24.04 LTSのインストール
if (-not $SkipUbuntuInstall) {
    Write-Log "$UBUNTU_DISPLAY_NAME のインストール状況をチェックしています..."
    
    if (Test-UbuntuInstalled) {
        Write-Log "$UBUNTU_DISPLAY_NAME は既にインストールされています" "SUCCESS"
        
        # インストール済みの場合、動作確認
        if (Test-UbuntuRunning) {
            Write-Log "$UBUNTU_DISPLAY_NAME は正常に動作しています" "SUCCESS"
        } else {
            Write-Log "$UBUNTU_DISPLAY_NAME がインストールされていますが、正常に動作していません" "WARN"
            Write-Log "手動で初期設定を完了してください: wsl -d $UBUNTU_DISTRO_NAME" "WARN"
        }
    } else {
        Write-Log "$UBUNTU_DISPLAY_NAME をインストールしています..." 
        Write-Log "インストール中にユーザー名とパスワードの入力が求められます" "INFO"
        
        try {
            # Ubuntuのインストール実行
            wsl --install -d $UBUNTU_DISTRO_NAME
            
            if ($LASTEXITCODE -eq 0) {
                Write-Log "$UBUNTU_DISPLAY_NAME のインストールが開始されました" "SUCCESS"
                Write-Log "初期設定が完了するまでお待ちください..." "INFO"
                
                # インストール完了を待機（最大5分）
                $timeout = 300 # 5分
                $elapsed = 0
                $interval = 10
                
                while ($elapsed -lt $timeout) {
                    Start-Sleep -Seconds $interval
                    $elapsed += $interval
                    
                    if (Test-UbuntuRunning) {
                        Write-Log "$UBUNTU_DISPLAY_NAME の初期設定が完了しました" "SUCCESS"
                        break
                    }
                    
                    if ($elapsed % 60 -eq 0) {
                        Write-Log "初期設定を待機中... ($([math]::Round($elapsed/60))分経過)" "INFO"
                    }
                }
                
                if ($elapsed -ge $timeout) {
                    Write-Log "$UBUNTU_DISPLAY_NAME の初期設定がタイムアウトしました" "WARN"
                    Write-Log "手動で初期設定を完了してください: wsl -d $UBUNTU_DISTRO_NAME" "WARN"
                }
            } else {
                Write-Log "$UBUNTU_DISPLAY_NAME のインストールに失敗しました (Exit Code: $LASTEXITCODE)" "ERROR"
                Write-Log "手動でインストールを行ってください: wsl --install -d $UBUNTU_DISTRO_NAME" "WARN"
            }
        }
        catch {
            Write-Log "$UBUNTU_DISPLAY_NAME のインストール中にエラーが発生しました: $($_.Exception.Message)" "ERROR"
            Write-Log "手動でインストールを行ってください: wsl --install -d $UBUNTU_DISTRO_NAME" "WARN"
        }
    }
    
    # Ubuntu初期設定の確認とガイド
    if (Test-UbuntuInstalled) {
        Write-Log "$UBUNTU_DISPLAY_NAME の初期設定確認を行います..." "INFO"
        
        try {
            # sudoの動作確認
            $sudoTest = wsl -d $UBUNTU_DISTRO_NAME --exec sudo echo "sudo test" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "sudo権限が正常に設定されています" "SUCCESS"
            } else {
                Write-Log "sudo権限の設定に問題がある可能性があります" "WARN"
                Write-Log "Ubuntu内で以下のコマンドを実行してください: sudo usermod -aG sudo `$USER" "INFO"
            }
            
            # システムの更新推奨
            Write-Log "Ubuntu内でシステムの更新を実行することを推奨します:" "INFO"
            Write-Log "  wsl -d $UBUNTU_DISTRO_NAME" "INFO"
            Write-Log "  sudo apt update && sudo apt upgrade -y" "INFO"
            
        }
        catch {
            Write-Log "Ubuntu初期設定の確認中にエラーが発生しました: $($_.Exception.Message)" "WARN"
        }
    }
} else {
    Write-Log "$UBUNTU_DISPLAY_NAME のインストールをスキップしました" "INFO"
}

Write-Log "WSL2のセットアップが完了しました" "SUCCESS"

if (-not $SkipUbuntuInstall -and (Test-UbuntuInstalled)) {
    Write-Log "次のステップ: VS Codeのセットアップ" "INFO"
    Write-Log "  - Remote WSL拡張機能のインストール" "INFO"
    Write-Log "  - Docker拡張機能の設定" "INFO"
    Write-Log "  - Git連携設定" "INFO"
} else {
    Write-Log "次のステップ: $UBUNTU_DISPLAY_NAME のインストール" "INFO"
    Write-Log "コマンド: wsl --install -d $UBUNTU_DISTRO_NAME" "INFO"
}
