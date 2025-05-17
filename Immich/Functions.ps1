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