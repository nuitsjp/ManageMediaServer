function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','Verbose')][string]$Level = 'INFO'
    )
    switch ($Level) {
        'INFO'    { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        'WARN'    { Write-Warning $Message }
        'ERROR'   { Write-Error $Message }
        'Verbose' { Write-Verbose $Message }
    }
}

function Read-PasswordTwice {
    param (
        [string]$Prompt = "パスワードを入力してください "
    )
    while ($true) {
        $password1 = Read-Host -AsSecureString -Prompt $Prompt
        $password2 = Read-Host -AsSecureString -Prompt "もう一度パスワードを入力してください"
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1))
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2))
        if ($plain1 -eq $plain2) {
            return $plain1
        } else {
            Write-Host "パスワードが一致しません。再度入力してください。" -ForegroundColor Yellow
        }
    }
}

function Test-WSLUserExists {
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [string]$Distro = "Ubuntu"
    )
    Write-Log -Message "WSLディストリビューション '$Distro' にユーザー '$UserName' が存在するか確認します。" -Level "INFO"
    $result = wsl -d $Distro getent passwd $UserName 2>$null
    if (-not [string]::IsNullOrEmpty($result)) {
        Write-Log -Message "ユーザー '$UserName' は存在します。" -Level "INFO"
        return $true
    } else {
        Write-Log -Message "ユーザー '$UserName' は存在しません。" -Level "INFO"
        return $false
    }
}

function Convert-WindowsPathToWSLPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath,
        [string]$Distro = "Ubuntu"
    )
    # パスのバックスラッシュをエスケープ
    $escapedPath = $WindowsPath.Replace('\', '\\')
    $cmd = "wsl -d $Distro -- wslpath '$escapedPath'"
    $wslPath = (Invoke-Expression $cmd).Trim().Replace('"', '')
    return $wslPath
}