function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    switch ($Level) {
        'INFO' { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        'WARN' { Write-Warning $Message }
        'ERROR'{ Write-Error $Message }
    }
}

function Read-PasswordTwice {
    param (
        [string]$Prompt = "パスワードを入力してください "
    )
    while ($true) {
        $password1 = Read-Host -AsSecureString -Prompt $Prompt
        $password2 = Read-Host -AsSecureString -Prompt "もう一度パスワードを入力してください"
        if (([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1))) -eq
            ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2)))) {
            return $password1
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

function New-WSLUser {
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [System.Security.SecureString]$Password,
        [string]$Distro = "Ubuntu"
    )
    Write-Log -Message "WSLディストリビューション '$Distro' にユーザー '$UserName' を作成します。" -Level "INFO"

    # SecureStringを平文に変換
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    )

    # ユーザー作成とパスワード設定をスクリプトで実行（bash -c quoting 問題を回避）
    $bashScript = @"
sudo useradd -m $UserName
echo "`"$($UserName):$plainPassword`"" | sudo chpasswd
"@
    $bashScript | wsl -d $Distro -- bash -s

    # 作成結果の確認
    if (Test-WSLUserExists -UserName $UserName -Distro $Distro) {
        Write-Log -Message "ユーザー '$UserName' の作成に成功しました。" -Level "INFO"
    } else {
        Write-Log -Message "ユーザー '$UserName' の作成に失敗しました。" -Level "ERROR"
        exit 1
    }
}