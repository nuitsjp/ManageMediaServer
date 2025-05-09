#!/usr/bin/env pwsh

# デバッグ用に環境変数を設定してからStart-Immich.ps1を実行するスクリプト

# 環境変数の設定（既定値を使用）
[Environment]::SetEnvironmentVariable('IMMICH_UPLOAD_LOCATION', 'D:\immich-photos', 'Machine')
[Environment]::SetEnvironmentVariable('IMMICH_DB_DATA_LOCATION', 'D:\immich-postgres', 'Machine')
[Environment]::SetEnvironmentVariable('IMMICH_TIMEZONE', 'Asia/Tokyo', 'Machine')

# Start-Immich.ps1の実行
& "$PSScriptRoot\Start-Immich.ps1"
