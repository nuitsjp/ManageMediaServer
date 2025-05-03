param(
    [Parameter(Mandatory=$true)]
    [string]$DestinationRootPath # 年別フォルダの親パスを受け取る引数を追加
)

# ---------------------------------------------
# 設定セクション
# ---------------------------------------------
# OneDrive リモート（rclone の名称）
$oneDrivePath   = "onedrive:公開資料"
# ローカル作業ディレクトリのルート（スクリプトと同じ階層の work）
$baseDirectory  = "$PSScriptRoot\work" # 元の定義に戻す
# ログ保存ディレクトリ
$logDir         = "$PSScriptRoot\logs"

# ---------------------------------------------
# 初期化：ディレクトリとログ設定
# ---------------------------------------------
# ログディレクトリがなければ作成
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory | Out-Null
}
# 基本ディレクトリ(work)が存在すれば削除し、再作成
if (Test-Path $baseDirectory) { # $BaseDirectoryPath を $baseDirectory に戻す
    Remove-Item -Path $baseDirectory -Recurse -Force # $BaseDirectoryPath を $baseDirectory に戻す
}
New-Item -Path $baseDirectory -ItemType Directory | Out-Null # $BaseDirectoryPath を $baseDirectory に戻す

# 実行日時を含むログファイル名
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile   = Join-Path $logDir "onedrive_move_$timestamp.log"

# 30日以上前のログを削除
Get-ChildItem -Path $logDir -Filter "onedrive_move_*.log" |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
  Remove-Item -Force

# ---------------------------------------------
# ステップ1：rclone で動画ファイルを移動
# ---------------------------------------------
# rclone 実行（テスト時は --dry-run を残し、本番運用時は外してください）
rclone move $oneDrivePath $baseDirectory `
    --include "*.mp4" --include "*.avi" --include "*.mov" `
    --include "*.mkv" --include "*.wmv" --include "*.flv" `
    --log-file $logFile --log-level INFO

# ---------------------------------------------
# ステップ2：移動済みファイルを年別フォルダへ振り分け
# ---------------------------------------------
# Shell.Application を使ってメディア作成日時を取得
$shell = New-Object -ComObject Shell.Application

Get-ChildItem -Path $baseDirectory -File | ForEach-Object { # $BaseDirectoryPath を $baseDirectory に戻す
    try {
        $folder = $shell.Namespace($_.DirectoryName)
        $file   = $folder.ParseName($_.Name)
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

        # 年フォルダ作成 (★修正箇所)
        $targetDir = Join-Path $DestinationRootPath $year # ベースを $DestinationRootPath に変更
        if (-not (Test-Path $targetDir)) {
            New-Item -Path $targetDir -ItemType Directory | Out-Null
        }

        # 年フォルダへ移動
        Move-Item -Path $_.FullName -Destination $targetDir -Force
        Write-Host "Moved '$($_.Name)' → '$($targetDir)\'" # 出力パスを修正
    }
    catch {
        Write-Warning "Error processing '$($_.Name)': $_"
    }
}

Write-Host "=== 完了 ==="
