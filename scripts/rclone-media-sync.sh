#!/bin/bash

# rclone メディア同期スクリプト
# 画像: 同期のみ（クラウド側保持）
# 動画: 移動（クラウド側削除）

set -euo pipefail

# 設定
REMOTE_NAME="cloudstorageremote"
LOCAL_DIR="/mnt/data/immich/external"
BACKUP_DIR="/mnt/backup/immich-backup"
CONFIG_FILE="/mnt/data/config/rclone/rclone.conf"
LOG_DIR="/mnt/data/config/rclone/logs"
LOG_FILE="${LOG_DIR}/media-sync.log"

# ログ関数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ディレクトリ作成
mkdir -p "$LOCAL_DIR" "$BACKUP_DIR" "$LOG_DIR"

# 設定確認
if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: rclone設定ファイルが見つかりません: $CONFIG_FILE"
    exit 1
fi

log "=== rclone メディア同期開始 ==="

# 1. 画像ファイルの同期（JPG, PNG）
log "画像ファイル同期開始..."
rclone sync "$REMOTE_NAME:/" "$LOCAL_DIR" \
    --config="$CONFIG_FILE" \
    --include="*.jpg" \
    --include="*.jpeg" \
    --include="*.JPG" \
    --include="*.JPEG" \
    --include="*.png" \
    --include="*.PNG" \
    --log-file="$LOG_FILE" \
    --log-level INFO \
    --progress || {
    log "ERROR: 画像同期に失敗しました"
    exit 1
}
log "画像ファイル同期完了"

# 2. 動画ファイルの移動（MOV, MP4）
log "動画ファイル移動開始..."

# 2-1. 動画をローカルにダウンロード
rclone copy "$REMOTE_NAME:/" "$LOCAL_DIR" \
    --config="$CONFIG_FILE" \
    --include="*.mov" \
    --include="*.MOV" \
    --include="*.mp4" \
    --include="*.MP4" \
    --log-file="$LOG_FILE" \
    --log-level INFO \
    --progress || {
    log "ERROR: 動画ダウンロードに失敗しました"
    exit 1
}

# 2-2. 動画ファイルをバックアップにコピー
log "動画ファイルバックアップ開始..."
rsync -av --include="*.mov" --include="*.MOV" --include="*.mp4" --include="*.MP4" --exclude="*" \
    "$LOCAL_DIR/" "$BACKUP_DIR/" || {
    log "WARNING: 動画バックアップに失敗しました"
}

# 2-3. クラウドから動画ファイルを削除
log "クラウドから動画ファイル削除開始..."
rclone delete "$REMOTE_NAME:/" \
    --config="$CONFIG_FILE" \
    --include="*.mov" \
    --include="*.MOV" \
    --include="*.mp4" \
    --include="*.MP4" \
    --log-file="$LOG_FILE" \
    --log-level INFO || {
    log "ERROR: クラウドからの動画削除に失敗しました"
    exit 1
}

log "動画ファイル移動完了"

# 3. 統計情報を取得
log "=== 同期結果統計 ==="
if [[ -d "$LOCAL_DIR" ]]; then
    IMG_COUNT=$(find "$LOCAL_DIR" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.JPG" -o -name "*.JPEG" -o -name "*.png" -o -name "*.PNG" \) | wc -l)
    VIDEO_COUNT=$(find "$LOCAL_DIR" -type f \( -name "*.mov" -o -name "*.MOV" -o -name "*.mp4" -o -name "*.MP4" \) | wc -l)
    TOTAL_COUNT=$(find "$LOCAL_DIR" -type f | wc -l)
    
    log "画像ファイル: ${IMG_COUNT}個"
    log "動画ファイル: ${VIDEO_COUNT}個"
    log "総ファイル数: ${TOTAL_COUNT}個"
fi

log "=== rclone メディア同期完了 ==="
