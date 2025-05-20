# rcloneをインストールするためのPowerShellスクリプト

# rcloneのインストール
$ErrorActionPreference = "Stop"

# rcloneの最新バージョンを取得
$rcloneVersion = (Invoke-WebRequest -Uri "https://rclone.org/downloads/" | Select-String -Pattern "rclone-v\d+\.\d+\.\d+-windows-amd64.zip" | ForEach-Object { $_.Matches.Value })[0]

# rcloneのダウンロードURL
$rcloneUrl = "https://downloads.rclone.org/$rcloneVersion"

# ダウンロード先のパス
$downloadPath = "$env:TEMP\rclone.zip"

# rcloneをダウンロード
Invoke-WebRequest -Uri $rcloneUrl -OutFile $downloadPath

# 解凍先のディレクトリ
$extractPath = "$env:TEMP\rclone"

# 解凍
Expand-Archive -Path $downloadPath -DestinationPath $extractPath -Force

# rcloneのインストール
$installPath = "C:\Program Files\rclone"
New-Item -ItemType Directory -Path $installPath -Force
Copy-Item -Path "$extractPath\rclone.exe" -Destination $installPath -Force

# 環境変数にrcloneのパスを追加
$envPath = [System.Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine)
if (-not $envPath.Contains($installPath)) {
    [System.Environment]::SetEnvironmentVariable("Path", "$envPath;$installPath", [System.EnvironmentVariableTarget]::Machine)
}

# rcloneのインストール確認
$rcloneCheck = & rclone version
if ($rcloneCheck) {
    Write-Host "rcloneのインストールが完了しました。"
} else {
    Write-Host "rcloneのインストールに失敗しました。"
}

# 一時ファイルのクリーンアップ
Remove-Item -Path $downloadPath -Force
Remove-Item -Path $extractPath -Recurse -Force