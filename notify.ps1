. $PSScriptRoot\secrets.ps1

$redirectUri = "https://localhost"

# スコープ設定
$scopes = "Mail.Send"

# トークン取得用のURL
$tokenUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/token"

# 認証コードを取得するためのURL（一度だけ実行する部分）
$authUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=$clientId&response_type=code&redirect_uri=$redirectUri&response_mode=query&scope=$scopes&state=12345"

# ※最初に一度だけ実行し、認証コードを取得
Start-Process $authUrl
# 認証後にリダイレクトされたURLから?code=以降の値をコピーし、以下に貼り付け
