#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory=$true)]
    [string]$VideosDirectory,
    [Parameter(Mandatory=$true)]
    [string]$BackupDirectory
)

$ErrorActionPreference = "Stop"

# Slack通知関数をインポート
. "$PSScriptRoot\Send-SlackNotification.ps1"

# ---------------------------------------------
# 設定セクション
# ---------------------------------------------
# OneDrive リモート（rclone の名称）
$oneDrivePath   = "onedrive:"
# ローカル作業ディレクトリのルート（スクリプトと同じ階層の work）
$workDirectory  = "$PSScriptRoot\work"
# ログ保存ディレクトリ
$logDir         = "$PSScriptRoot\logs"
# 個人動画フォルダ（OneDrive の Videos バックアップ先フォルダ）
$MyVideosDirectory = Join-Path $VideosDirectory 'MyVideos'
# 画像バックアップ先ディレクトリ
$PicturesDirectory = Join-Path $BackupDirectory 'Pictures'
# OneDrive上の画像フォルダ
$oneDrivePicturesPath = "onedrive:Pictures"
# ログファイルのタイムスタンプ
$timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"

# ---------------------------------------------
# 初期化：ディレクトリとログ設定
# ---------------------------------------------
try {
    Send-SlackNotification -Status "情報" -Message "バックアップ処理を開始します。"
    # ログディレクトリがなければ作成
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory | Out-Null
    }
    # 基本ディレクトリ(work)が存在すれば削除し、再作成
    if (Test-Path $workDirectory) {
        Remove-Item -Path $workDirectory -Recurse -Force
    }
    New-Item -Path $workDirectory -ItemType Directory | Out-Null

    # Picturesディレクトリがなければ作成
    if (-not (Test-Path $PicturesDirectory)) {
        New-Item -Path $PicturesDirectory -ItemType Directory | Out-Null
    }

    # 30日以上前のログを削除
    Get-ChildItem -Path $logDir -Filter "*.log" |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
      Remove-Item -Force
} catch {
    Send-SlackNotification -Status "失敗" -Message "初期化処理でエラーが発生しました。" -Exception $_.Exception
    throw
}

# ---------------------------------------------
try {
    # ステップ1：rclone で動画ファイルを移動
    # ---------------------------------------------
    # rclone 実行
    $oneDriveLogFile   = Join-Path $logDir "onedrive_move_$timestamp.log"
    rclone move $oneDrivePath $workDirectory `
        --include "*.mp4" --include "*.avi" --include "*.mov" `
        --include "*.mkv" --include "*.wmv" --include "*.flv" `
        --log-file $oneDriveLogFile --log-level INFO
    if ($LASTEXITCODE -ne 0) {
        $logContent = Get-Content $oneDriveLogFile -Raw
        $errorMessage = "rclone実行中にエラーが発生しました。ログ内容:`n$logContent"
        Send-SlackNotification -Status "失敗" -Message $errorMessage
        throw $errorMessage
    }

    # ---------------------------------------------
    # ステップ1.5：rcloneで画像ファイルをPicturesディレクトリへコピー
    # ---------------------------------------------
    $picturesLogFile = Join-Path $logDir "onedrive_pictures_copy_$timestamp.log"
    rclone copy $oneDrivePicturesPath $PicturesDirectory `
        --include "*.jpg" --include "*.jpeg" --include "*.png" --include "*.mp" `
        --log-file $picturesLogFile --log-level INFO
    if ($LASTEXITCODE -ne 0) {
            $logContent = Get-Content $picturesLogFile -Raw
        $errorMessage = "rclone画像コピー中にエラーが発生しました。ログ内容:`n$logContent"
        Send-SlackNotification -Status "失敗" -Message $errorMessage
        throw $errorMessage
    }

    # ---------------------------------------------
    # ステップ2：移動済みファイルを年別フォルダへ振り分け
    # ---------------------------------------------
    # Shell.Application を使ってメディア作成日時を取得
    $shell = New-Object -ComObject Shell.Application

    Get-ChildItem -Path $workDirectory -Recurse -File | ForEach-Object {
        try {
            $folder = $shell.Namespace($_.DirectoryName)
            $file   = $folder.ParseName($_.Name)

            # $fileをコンソールへ出力（デバッグ用）
            Write-Host "Processing file: $($_.FullName)"

            # プロパティ208: メディア作成日時
            $rawDate = $folder.GetDetailsOf($file, 208) -replace '[^\d/]', ''
            if ($rawDate -match '(\d{4}/\d{1,2}/\d{1,2})') {
                $dateStr = $matches[1]
                try {
                    $year = [datetime]::ParseExact($dateStr, "yyyy/M/d", $null).Year
                } catch {
                    $year = $_.CreationTime.Year
                }
            } else {
                $year = $_.CreationTime.Year
            }

            # 年フォルダ作成
            $targetDir = Join-Path $MyVideosDirectory $year
            if (-not (Test-Path $targetDir)) {
                New-Item -Path $targetDir -ItemType Directory | Out-Null
            }

            # 年フォルダへ移動
            Move-Item -Path $_.FullName -Destination $targetDir -Force
            Write-Host "Moved '$($_.Name)' → '$($targetDir)\'"
            Send-SlackNotification -Status "成功" -Message "ファイル '$($_.Name)' を '$($targetDir)\' へ移動しました。"
        }
        catch {
            Write-Warning "Error processing '$($_.Name)': $_"
            Send-SlackNotification -Status "失敗" -Message "ファイル '$($_.Name)' の処理中にエラーが発生しました。" -Exception $_.Exception
        }
    }

    # ---------------------------------------------
    # ステップ3：Videoフォルダをバックアップする
    # ---------------------------------------------

    $robocopyLogFile   = Join-Path $logDir "robocopy_$timestamp.log"

    # バックアップ実行
    # robocopy は Windows 専用コマンド。PowerShell Core でも Windows 上で実行可能。
    # /E: サブディレクトリ含む, /R:3 再試行3回, /W:10 待機10秒, /MT:16 マルチスレッド
    robocopy $VideosDirectory $BackupDirectory /E /R:3 /W:10 /MT:16 /LOG:$robocopyLogFile
    if ($LASTEXITCODE -gt 2) {
        Write-Host "Backup failed with error code: $LASTEXITCODE"
        Send-SlackNotification -Status "失敗" -Message "バックアップ処理中にエラーが発生しました。エラーコード: $LASTEXITCODE"
        throw "バックアップ処理中にエラーが発生しました。エラーコード: $LASTEXITCODE"
    }

    Send-SlackNotification -Status "成功" -Message "バックアップ処理が正常に完了しました。"
}
catch {
    $errorTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $errorLogFile = Join-Path $logDir "error_$errorTimestamp.log"
    $errorText = "[$errorTimestamp] エラー発生:`n$($_ | Out-String)"
    $errorText | Set-Content -Path $errorLogFile -Encoding UTF8
    Send-SlackNotification -Status "失敗" -Message "スクリプト実行中にエラーが発生しました。詳細は $errorLogFile を参照してください。" -Exception $_.Exception
    exit -1
}
