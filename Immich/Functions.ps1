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

function Read-PasswordWithConfirmation {
    <#
    .SYNOPSIS
        ディストリの有無を確認し、必要な場合のみパスワード入力を促す。SecureStringは平文に変換される。
    .PARAMETER DistributionName
        チェック対象のWSLディストリ名（省略時は $script:Distro）
    .OUTPUTS
        string - 入力されたパスワード（平文、または不要時は空文字列）
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$DistributionName = $script:Distro
    )
    
    # ディストリの有無を判定
    if (-not (Test-WslDistribution -DistributionName $DistributionName)) {
        $needPassword = $true
    } else {
        $WSLUserName = "ubuntu"
        $userExists = $false
        try {
            $userId = wsl -d $DistributionName -- id -u $WSLUserName 2>$null
            $userExists = $null -ne $userId -and $userId -match '^[0-9]+$'
        } catch {
            $userExists = $false
        }
        $needPassword = -not $userExists
    }

    if ($needPassword) {
        $password = ""
        $passwordConfirm = ""
        while ([string]::IsNullOrWhiteSpace($password) -or ($password -ne $passwordConfirm)) {
            if ($password -ne $passwordConfirm -and -not [string]::IsNullOrWhiteSpace($password)) {
                Write-Log "パスワードが一致しません。再度入力してください。" -Level WARN
            }
            $securePassword = Read-Host "パスワードを入力してください" -AsSecureString
            $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword))
            $securePasswordConfirm = Read-Host "パスワードを再入力してください" -AsSecureString
            $passwordConfirm = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePasswordConfirm))
        }
        return $password
    } else {
        Write-Log "既存のubuntuユーザーが存在するため、パスワード入力はスキップします。"
        return ""
    }
}

function Install-WslDistributionAndWait {
    <#
    .SYNOPSIS
        指定したWSLディストリビューションをインストールし、起動を待機します。
    .PARAMETER DistributionName
        インストール・起動確認対象のWSLディストリ名（省略時は $script:Distro）
    .OUTPUTS
        なし（失敗時は例外をthrow）
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$DistributionName = $script:Distro
    )

    Write-Log "$DistributionName ディストリビューションをインストールします。"
    wsl --install -d $DistributionName
    Write-Log "$DistributionName のインストールが完了しました。"

    # WSLが起動するまで待機
    Write-Log "WSLの起動を待機しています..."
    $retryCount = 0
    $maxRetries = 10
    $success = $false

    while (-not $success -and $retryCount -lt $maxRetries) {
        try {
            Start-Sleep -Seconds 2
            $result = wsl -d $DistributionName -- echo "WSL is ready"
            if ($result -eq "WSL is ready") {
                $success = $true
                Write-Log "WSLが正常に起動しました。"
            }
        } catch {
            $retryCount++
            Write-Log "WSLの起動を待機中... ($retryCount/$maxRetries)"
        }
    }

    if (-not $success) {
        throw "WSLの起動を確認できませんでした。処理を中断します。"
    }
}