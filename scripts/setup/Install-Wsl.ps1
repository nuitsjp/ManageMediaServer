# WSL Ubuntu 24.04 セットアップスクリプト（systemd有効化対応）
# 冪等性を考慮し、既存環境の再設定にも対応

param(
    [switch]$Force,
    [switch]$Debug,
    [string]$DistroName = "Ubuntu-24.04"
)

# エラー処理設定
$ErrorActionPreference = "Stop"

# ログ関数
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR" { "Red" }
        "DEBUG" { "Gray" }
        default { "White" }
    }
    
    if ($Level -eq "DEBUG" -and -not $Debug) {
        return
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# 管理者権限チェック
function Test-AdminRights {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# WSL機能有効化チェック・実行
function Enable-WSLFeature {
    Write-Log "WSL機能の状態を確認中..." -Level INFO
    
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
    $vmFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    
    $needsReboot = $false
    
    if ($wslFeature.State -ne "Enabled") {
        Write-Log "WSL機能を有効化中..." -Level INFO
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
        $needsReboot = $true
    } else {
        Write-Log "WSL機能は既に有効です" -Level SUCCESS
    }
    
    if ($vmFeature.State -ne "Enabled") {
        Write-Log "仮想マシンプラットフォーム機能を有効化中..." -Level INFO
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
        $needsReboot = $true
    } else {
        Write-Log "仮想マシンプラットフォーム機能は既に有効です" -Level SUCCESS
    }
    
    if ($needsReboot) {
        Write-Log "WSL機能の有効化が完了しました。システムの再起動が必要です。" -Level WARNING
        Write-Log "再起動後、このスクリプトを再実行してください。" -Level WARNING
        exit 1
    }
}

# WSL2をデフォルトに設定
function Set-WSL2Default {
    Write-Log "WSL2をデフォルトバージョンに設定中..." -Level INFO
    try {
        wsl --set-default-version 2
        Write-Log "WSL2がデフォルトバージョンに設定されました" -Level SUCCESS
    }
    catch {
        Write-Log "WSL2の設定に失敗しました: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# Ubuntu 24.04のインストール状況確認
function Test-UbuntuInstallation {
    param([string]$DistroName)
    
    Write-Log "Ubuntu $DistroName のインストール状況を確認中..." -Level DEBUG
    
    try {
        $wslList = wsl -l -v | Where-Object { $_ -match $DistroName }
        if ($wslList) {
            Write-Log "$DistroName は既にインストールされています" -Level SUCCESS
            return $true
        }
    }
    catch {
        Write-Log "WSLディストリビューション一覧の取得に失敗しました" -Level DEBUG
    }
    
    return $false
}

# Ubuntu 24.04インストール
function Install-Ubuntu {
    param([string]$DistroName)
    
    if (Test-UbuntuInstallation -DistroName $DistroName) {
        if (-not $Force) {
            Write-Log "$DistroName は既にインストールされています。再インストールする場合は -Force オプションを使用してください。" -Level INFO
            return
        } else {
            Write-Log "強制再インストールを実行します..." -Level WARNING
            wsl --unregister $DistroName
        }
    }
    
    Write-Log "Ubuntu $DistroName をインストール中..." -Level INFO
    try {
        wsl --install -d $DistroName
        Write-Log "Ubuntu $DistroName のインストールが完了しました" -Level SUCCESS
    }
    catch {
        Write-Log "Ubuntu $DistroName のインストールに失敗しました: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# systemd設定確認
function Test-SystemdEnabled {
    param([string]$DistroName)
    
    Write-Log "systemd設定を確認中..." -Level DEBUG
    
    try {
        $wslConf = wsl -d $DistroName cat /etc/wsl.conf 2>$null
        if ($wslConf -match "systemd\s*=\s*true") {
            Write-Log "systemdは既に有効化されています" -Level SUCCESS
            return $true
        }
    }
    catch {
        Write-Log "wsl.confの確認に失敗しました（ファイルが存在しない可能性があります）" -Level DEBUG
    }
    
    return $false
}

# systemd有効化
function Enable-Systemd {
    param([string]$DistroName)
    
    if (Test-SystemdEnabled -DistroName $DistroName) {
        Write-Log "systemdは既に有効化されています" -Level SUCCESS
        return $false  # 再起動不要
    }
    
    Write-Log "systemdを有効化中..." -Level INFO
    
    # wsl.confファイルの作成・更新
    $wslConfContent = @"
[boot]
systemd=true

[user]
default=root
"@
    
    try {
        # 一時ファイルに内容を書き込み
        $tempFile = [System.IO.Path]::GetTempFileName()
        $wslConfContent | Out-File -FilePath $tempFile -Encoding UTF8
        
        # WSL内にコピー
        wsl -d $DistroName bash -c "mkdir -p /etc && cp /mnt/c/$(($tempFile -replace '\\', '/') -replace 'C:', '') /etc/wsl.conf"
        
        # 一時ファイル削除
        Remove-Item $tempFile -Force
        
        Write-Log "systemd設定が完了しました" -Level SUCCESS
        return $true  # 再起動必要
    }
    catch {
        Write-Log "systemd有効化に失敗しました: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# WSLディストリビューション再起動
function Restart-WSLDistro {
    param([string]$DistroName)
    
    Write-Log "$DistroName を再起動中..." -Level INFO
    
    try {
        wsl --terminate $DistroName
        Start-Sleep -Seconds 3
        wsl -d $DistroName echo "WSL再起動完了"
        Write-Log "$DistroName の再起動が完了しました" -Level SUCCESS
    }
    catch {
        Write-Log "$DistroName の再起動に失敗しました: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# systemd動作確認
function Test-SystemdRunning {
    param([string]$DistroName)
    
    Write-Log "systemdの動作状況を確認中..." -Level INFO
    
    try {
        $systemdStatus = wsl -d $DistroName systemctl is-system-running 2>$null
        if ($systemdStatus -match "running|degraded") {
            Write-Log "systemdは正常に動作しています (状態: $systemdStatus)" -Level SUCCESS
            return $true
        } else {
            Write-Log "systemdの状態が異常です (状態: $systemdStatus)" -Level WARNING
            return $false
        }
    }
    catch {
        Write-Log "systemdの状態確認に失敗しました: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

# 基本パッケージ更新
function Update-SystemPackages {
    param([string]$DistroName)
    
    Write-Log "システムパッケージを更新中..." -Level INFO
    
    try {
        wsl -d $DistroName bash -c "apt update && apt upgrade -y"
        Write-Log "システムパッケージの更新が完了しました" -Level SUCCESS
    }
    catch {
        Write-Log "システムパッケージの更新に失敗しました: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# メイン処理
function Main {
    Write-Log "=== WSL Ubuntu 24.04 + systemd セットアップ開始 ===" -Level INFO
    
    # 管理者権限チェック
    if (-not (Test-AdminRights)) {
        Write-Log "このスクリプトは管理者権限で実行する必要があります" -Level ERROR
        Write-Log "PowerShellを管理者として実行して、再度実行してください" -Level ERROR
        exit 1
    }
    
    try {
        # 1. WSL機能有効化
        Enable-WSLFeature
        
        # 2. WSL2をデフォルトに設定
        Set-WSL2Default
        
        # 3. Ubuntu 24.04インストール
        Install-Ubuntu -DistroName $DistroName
        
        # 4. systemd有効化
        $needsRestart = Enable-Systemd -DistroName $DistroName
        
        # 5. 必要に応じてWSL再起動
        if ($needsRestart) {
            Restart-WSLDistro -DistroName $DistroName
        }
        
        # 6. systemd動作確認
        if (-not (Test-SystemdRunning -DistroName $DistroName)) {
            Write-Log "systemdの動作確認に失敗しました。手動での確認をお勧めします。" -Level WARNING
        }
        
        # 7. システムパッケージ更新
        Update-SystemPackages -DistroName $DistroName
        
        Write-Log "=== WSL Ubuntu 24.04 + systemd セットアップ完了 ===" -Level SUCCESS
        
        # 次のステップ案内
        Write-Log "" -Level INFO
        Write-Log "次のステップ:" -Level INFO
        Write-Log "1. WSLに接続: wsl -d $DistroName" -Level INFO
        Write-Log "2. systemd確認: systemctl status" -Level INFO
        Write-Log "3. メディアサーバーセットアップ: cd /mnt/d/ManageMediaServer && ./scripts/setup/auto-setup.sh" -Level INFO
        
    }
    catch {
        Write-Log "セットアップ中にエラーが発生しました: $($_.Exception.Message)" -Level ERROR
        Write-Log "詳細なログを確認し、問題を解決してから再実行してください。" -Level ERROR
        exit 1
    }
}

# スクリプト実行
if ($MyInvocation.InvocationName -ne '.') {
    Main
}