#Requires -RunAsAdministrator

<#
.SYNOPSIS
    VS Code の WSL 開発環境セットアップスクリプト

.DESCRIPTION
    WSL での開発に必要な VS Code 拡張機能をインストールし、設定を行います。
    - Remote WSL 拡張機能
    - Docker 拡張機能
    - Git 連携設定の確認

.EXAMPLE
    .\Setup-VSCode.ps1
#>

# エラーハンドリング設定
$ErrorActionPreference = "Stop"
trap {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[ERROR] 行: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    exit 1
}

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

# VS Code がインストールされているかチェック
function Test-VSCodeInstalled {
    try {
        $null = Get-Command code -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# 拡張機能がインストール済みかチェック
function Test-ExtensionInstalled {
    param([string]$ExtensionId)
    
    $installedExtensions = code --list-extensions
    return $installedExtensions -contains $ExtensionId
}

# メイン処理開始
Write-Log "VS Code WSL 開発環境セットアップを開始します"

# VS Code インストールチェック
if (-not (Test-VSCodeInstalled)) {
    Write-Log "VS Code がインストールされていません" "ERROR"
    Write-Log "https://code.visualstudio.com/ からダウンロードしてインストールしてください" "ERROR"
    exit 1
}

Write-Log "VS Code が検出されました" "SUCCESS"

# 必要な拡張機能のリスト
$extensions = @(
    @{
        Id = "ms-vscode-remote.remote-wsl"
        Name = "Remote - WSL"
        Description = "WSL 内でのリモート開発"
    },
    @{
        Id = "ms-azuretools.vscode-docker"
        Name = "Docker"
        Description = "Docker コンテナの管理と開発"
    },
    @{
        Id = "ms-vscode.powershell"
        Name = "PowerShell"
        Description = "PowerShell スクリプト開発サポート"
    }
)

# 拡張機能のインストール
Write-Log "必要な拡張機能をインストールしています..."

foreach ($extension in $extensions) {
    if (Test-ExtensionInstalled -ExtensionId $extension.Id) {
        Write-Log "$($extension.Name) は既にインストールされています" "SUCCESS"
    }
    else {
        Write-Log "$($extension.Name) をインストールしています..."
        code --install-extension $extension.Id
        
        if ($LASTEXITCODE -eq 0) {
            Write-Log "$($extension.Name) のインストールが完了しました" "SUCCESS"
        }
        else {
            Write-Log "$($extension.Name) のインストールに失敗しました" "WARN"
        }
    }
}
