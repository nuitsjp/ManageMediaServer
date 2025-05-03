# ---------------------------------------------
# 設定セクション
# ---------------------------------------------
# OneDrive リモート（rclone の名称）
$oneDrivePath   = "onedrive:"
# ローカル作業ディレクトリのルート（MyVideosを含めたパス）
$baseDirectory  = "C:\Work\rclone\work\MyVideos"
# ログ保存ディレクトリ
$logDir         = "C:\Work\rclone\logs"
# 動画拡張子リスト
$videoExtensions = @(".mp4", ".avi", ".mov", ".mkv", ".wmv", ".flv")

# ---------------------------------------------
# 初期化：ディレクトリとログ設定
# ---------------------------------------------
# ログディレクトリがなければ作成
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory | Out-Null
}
# 基本ディレクトリがなければ作成
if (-not (Test-Path $baseDirectory)) {
    New-Item -Path $baseDirectory -ItemType Directory | Out-Null
}

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
rclone move `
  $oneDrivePath `
  $baseDirectory `
  --include "*.mp4" --include "*.avi" --include "*.mov" `
  --include "*.mkv" --include "*.wmv" --include "*.flv" `
  --log-file $logFile --log-level INFO

# ---------------------------------------------
# ステップ2：移動済みファイルを年別フォルダへ振り分け
# ---------------------------------------------
# 作業ディレクトリへ移動
Set-Location $baseDirectory

# Shell.Application を使ってメディア作成日時を取得
$shell = New-Object -ComObject Shell.Application

Get-ChildItem -File | ForEach-Object {
    $ext = $_.Extension.ToLower()
    if ($videoExtensions -contains $ext) {
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

            # 年フォルダ作成
            $targetDir = Join-Path $baseDirectory $year
            if (-not (Test-Path $targetDir)) {
                New-Item -Path $targetDir -ItemType Directory | Out-Null
            }

            # 年フォルダへ移動
            Move-Item -Path $_.FullName -Destination $targetDir -Force
            Write-Host "Moved '$($_.Name)' → '$year\'"
        }
        catch {
            Write-Warning "Error processing '$($_.Name)': $_"
        }
    }
}

Write-Host "=== 完了 ==="
