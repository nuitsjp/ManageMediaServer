# Ubuntuをインストール
wsl --install -d Ubuntu

# インストール完了後、WSLを起動してユーザー設定を促し、終了するメッセージを表示
Write-Host "Ubuntuがインストールされました。ユーザー名とパスワードを設定してください。"
Write-Host "設定が完了したら 'exit' と入力してWSLを終了してください。"

# WSLを起動
wsl

wsl -d Ubuntu -e bash -c "whoami"