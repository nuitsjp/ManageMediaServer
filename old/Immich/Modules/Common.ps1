$script:DistroName = "Ubuntu-24.04"
$script:WSLUserName = "ubuntu"
$script:ImmichDirWSL = "/opt/immich"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','VERBOSE')][string]$Level = 'INFO'
    )
    switch ($Level.ToUpper()) {
        'INFO'    { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        'WARN'    { Write-Warning "[WARN] $Message" }
        'ERROR'   { Write-Error "[ERROR] $Message" }
        'VERBOSE' { Write-Verbose "[VERBOSE] $Message" }
    }
}

trap {
    Write-Log "エラー: $($_.Exception.Message)" -Level "ERROR"
    break
}

function Read-PasswordTwice {
    [CmdletBinding()]
    param (
        [string]$Prompt = "パスワードを入力してください "
    )
    while ($true) {
        $password1 = Read-Host -AsSecureString -Prompt $Prompt
        $password2 = Read-Host -AsSecureString -Prompt "もう一度パスワードを入力してください"
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1))
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2))
        if ($plain1 -eq $plain2) {
            Write-Log "パスワードが一致しました。" -Level "INFO"
            return $plain1
        } else {
            Write-Log "パスワードが一致しません。再度入力してください。" -Level "WARN"
        }
    }
}
