#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

REMOTE_NAME="${REMOTE_NAME:-cloudstorageremote}"
REMOTE_SOURCE="${REMOTE_SOURCE:-${REMOTE_NAME}:/}"
LOCAL_DIR="${LOCAL_DIR:-/mnt/data/immich/external}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/backup/immich-backup}"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backup}"
CONFIG_FILE="${CONFIG_FILE:-/mnt/data/config/rclone/rclone.conf}"
LOG_DIR="${LOG_DIR:-/mnt/data/config/rclone/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/media-sync.log}"
EXCLUDE_FILE="${EXCLUDE_FILE:-${REPO_ROOT}/config/rclone/media-sync-excludes.txt}"
NOTIFICATION_ENV="${NOTIFICATION_ENV:-${REPO_ROOT}/config/env/notification.env}"
DATA_MIN_FREE_KIB="${DATA_MIN_FREE_KIB:-1048576}"
BACKUP_MIN_FREE_KIB="${BACKUP_MIN_FREE_KIB:-1048576}"
NO_DELETE=false

IMAGE_FILTERS=(
    "*.jpg"
    "*.jpeg"
    "*.png"
    "*.JPG"
    "*.JPEG"
    "*.PNG"
)
VIDEO_FILTERS=(
    "*.mov"
    "*.MOV"
    "*.mp4"
    "*.MP4"
)
MEDIA_FILTERS=("${IMAGE_FILTERS[@]}" "${VIDEO_FILTERS[@]}")

IMAGE_COPY_STATUS="not_run"
VIDEO_COPY_STATUS="not_run"
BACKUP_STATUS="not_run"
VERIFIED_COUNT=0
DELETED_COUNT=0
SKIPPED_VIDEO_COUNT=0
CURRENT_STEP="initializing"
VERIFIED_FILE=""
DRY_RUN_LOG=""
NOTIFICATION_ENV_LOADED=false
SUPPRESS_DISCORD="${SUPPRESS_DISCORD:-false}"
SUMMARY_FILE="${SUMMARY_FILE:-}"

usage() {
    cat <<'USAGE'
Usage: rclone-media-sync.sh [--no-delete]

Options:
  --no-delete  Copy images/videos and backup local files, but skip dry-run and remote deletion.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-delete)
            NO_DELETE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

mkdir -p "$LOG_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$1" | tee -a "$LOG_FILE"
}

load_notification_env() {
    if [[ "$NOTIFICATION_ENV_LOADED" == "true" ]]; then
        return 0
    fi
    if [[ -f "$NOTIFICATION_ENV" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "$NOTIFICATION_ENV"
        set +a
    fi
    NOTIFICATION_ENV_LOADED=true
}

notify_discord() {
    local status="$1"
    local message="$2"

    if [[ "$SUPPRESS_DISCORD" == "true" ]]; then
        log "Discord通知は抑止されています"
        return 0
    fi

    load_notification_env

    if [[ "${NOTIFICATION_ENABLED:-false}" != "true" ]]; then
        log "Discord通知は無効です"
        return 0
    fi

    if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
        log "WARNING: DISCORD_WEBHOOK_URL が未設定のため通知をスキップします"
        return 0
    fi

    if ! command -v curl >/dev/null; then
        log "WARNING: curl が見つからないため Discord 通知をスキップします"
        return 0
    fi

    local host now payload
    host=$(hostname)
    now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    payload=$(jq -n \
        --arg status "$status" \
        --arg host "$host" \
        --arg now "$now" \
        --arg message "$message" \
        --arg image "$IMAGE_COPY_STATUS" \
        --arg video "$VIDEO_COPY_STATUS" \
        --arg backup "$BACKUP_STATUS" \
        --arg verified "$VERIFIED_COUNT" \
        --arg deleted "$DELETED_COUNT" \
        --arg skipped "$SKIPPED_VIDEO_COUNT" \
        --arg no_delete "$NO_DELETE" \
        --arg log_file "$LOG_FILE" \
        '{content: ("**rclone media sync " + $status + "**\n"
            + "host: `" + $host + "`\n"
            + "time: `" + $now + "`\n"
            + "message: " + $message + "\n"
            + "image copy: `" + $image + "`\n"
            + "video copy: `" + $video + "`\n"
            + "backup: `" + $backup + "`\n"
            + "verified videos: `" + $verified + "`\n"
            + "deleted videos: `" + $deleted + "`\n"
            + "skipped videos: `" + $skipped + "`\n"
            + "no-delete: `" + $no_delete + "`\n"
            + "log: `" + $log_file + "`")}')

    if ! curl -fsS -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null; then
        log "WARNING: Discord通知に失敗しました"
    fi
}

write_summary() {
    [[ -n "$SUMMARY_FILE" ]] || return 0

    local status="$1"
    local message="$2"
    {
        printf 'RCLONE_SYNC_STATUS=%q\n' "$status"
        printf 'RCLONE_SYNC_MESSAGE=%q\n' "$message"
        printf 'RCLONE_IMAGE_COPY_STATUS=%q\n' "$IMAGE_COPY_STATUS"
        printf 'RCLONE_VIDEO_COPY_STATUS=%q\n' "$VIDEO_COPY_STATUS"
        printf 'RCLONE_BACKUP_STATUS=%q\n' "$BACKUP_STATUS"
        printf 'RCLONE_VERIFIED_COUNT=%q\n' "$VERIFIED_COUNT"
        printf 'RCLONE_DELETED_COUNT=%q\n' "$DELETED_COUNT"
        printf 'RCLONE_SKIPPED_VIDEO_COUNT=%q\n' "$SKIPPED_VIDEO_COUNT"
        printf 'RCLONE_NO_DELETE=%q\n' "$NO_DELETE"
        printf 'RCLONE_LOG_FILE=%q\n' "$LOG_FILE"
        printf 'RCLONE_VERIFIED_FILE=%q\n' "$VERIFIED_FILE"
        printf 'RCLONE_DRY_RUN_LOG=%q\n' "$DRY_RUN_LOG"
    } > "$SUMMARY_FILE"
}

on_exit() {
    local exit_code=$?
    local status message
    trap - EXIT
    if [[ $exit_code -eq 0 ]]; then
        status="succeeded"
        message="media sync completed"
    else
        status="failed"
        message="failed at step: ${CURRENT_STEP}"
    fi
    write_summary "$status" "$message"
    notify_discord "$status" "$message"
    exit "$exit_code"
}

trap on_exit EXIT

rclone_common_args() {
    if [[ -f "$CONFIG_FILE" ]]; then
        printf '%s\0%s\0' "--config" "$CONFIG_FILE"
    fi
    printf '%s\0%s\0%s\0%s\0' "--log-file" "$LOG_FILE" "--log-level" "INFO"
}

build_filter_file() {
    local filter_file="$1"
    shift
    local patterns=("$@")
    local pattern

    : > "$filter_file"
    while IFS= read -r pattern; do
        [[ -n "$pattern" ]] || continue
        printf -- '- %s\n' "$pattern" >> "$filter_file"
    done < "$EXCLUDE_FILE"

    for pattern in "${patterns[@]}"; do
        printf -- '+ %s\n' "$pattern" >> "$filter_file"
    done
    printf -- '- **\n' >> "$filter_file"
}

run_rclone_copy() {
    local label="$1"
    local src="$2"
    local dst="$3"
    shift 3
    local filters=("$@")
    local common=()
    local filter_file
    filter_file=$(mktemp)
    build_filter_file "$filter_file" "${filters[@]}"
    mapfile -d '' -t common < <(rclone_common_args)

    log "${label} copy 開始: ${src} -> ${dst}"
    rclone copy "$src" "$dst" \
        "${common[@]}" \
        --filter-from "$filter_file"
    rm -f "$filter_file"
    log "${label} copy 完了"
}

available_kib_for_path() {
    df -Pk "$1" | awk 'NR == 2 {print $4}'
}

assert_min_free_kib() {
    local label="$1"
    local path="$2"
    local min_free_kib="$3"
    local available_kib

    available_kib=$(available_kib_for_path "$path")
    if [[ -z "$available_kib" ]]; then
        log "ERROR: 空き容量を確認できません: ${path}"
        exit 1
    fi
    if (( available_kib < min_free_kib )); then
        log "ERROR: ${label} の空き容量不足: path=${path} available=${available_kib}KiB required=${min_free_kib}KiB"
        exit 1
    fi
    log "${label} 空き容量 OK: path=${path} available=${available_kib}KiB required=${min_free_kib}KiB"
}

assert_prerequisites() {
    CURRENT_STEP="preflight"
    command -v rclone >/dev/null || { log "ERROR: rclone が見つかりません"; exit 1; }
    command -v jq >/dev/null || { log "ERROR: jq が見つかりません"; exit 1; }
    load_notification_env
    if [[ "${NOTIFICATION_ENABLED:-false}" == "true" ]]; then
        command -v curl >/dev/null || { log "ERROR: Discord通知が有効ですが curl が見つかりません"; exit 1; }
    fi

    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        log "ERROR: 除外ファイルが見つかりません: $EXCLUDE_FILE"
        exit 1
    fi

    if [[ "$REMOTE_SOURCE" == *:* && ! -f "$CONFIG_FILE" ]]; then
        log "ERROR: rclone設定ファイルが見つかりません: $CONFIG_FILE"
        exit 1
    fi

    mkdir -p "$LOCAL_DIR" "$BACKUP_DIR"

    if [[ ! -d "$LOCAL_DIR" ]]; then
        log "ERROR: ローカル同期先がディレクトリではありません: $LOCAL_DIR"
        exit 1
    fi
    if [[ ! -w "$LOCAL_DIR" ]]; then
        log "ERROR: ローカル同期先に書き込めません: $LOCAL_DIR"
        exit 1
    fi
    if ! mountpoint -q "$BACKUP_ROOT"; then
        log "ERROR: バックアップルートがマウントされていません: $BACKUP_ROOT"
        exit 1
    fi
    if [[ ! -w "$BACKUP_DIR" ]]; then
        log "ERROR: バックアップ先に書き込めません: $BACKUP_DIR"
        exit 1
    fi

    log "容量確認:"
    df -h "$LOCAL_DIR" "$BACKUP_ROOT" | tee -a "$LOG_FILE"
    assert_min_free_kib "ローカル同期先" "$LOCAL_DIR" "$DATA_MIN_FREE_KIB"
    assert_min_free_kib "バックアップ先" "$BACKUP_ROOT" "$BACKUP_MIN_FREE_KIB"
}

build_verified_file_list() {
    CURRENT_STEP="build verified file list"
    local timestamp remote_json filter_file path size local_path backup_path local_size backup_size
    timestamp=$(date '+%Y%m%d-%H%M%S')
    VERIFIED_FILE="${LOG_DIR}/verified-files-${timestamp}.txt"
    DRY_RUN_LOG="${LOG_DIR}/delete-dry-run-${timestamp}.log"
    remote_json=$(mktemp)
    filter_file=$(mktemp)
    : > "$VERIFIED_FILE"
    build_filter_file "$filter_file" "${VIDEO_FILTERS[@]}"

    local common=()
    mapfile -d '' -t common < <(rclone_common_args)

    log "remote 動画候補の列挙開始"
    rclone lsjson "$REMOTE_SOURCE" \
        --recursive \
        --files-only \
        "${common[@]}" \
        --filter-from "$filter_file" > "$remote_json"

    while IFS=$'\t' read -r path size; do
        [[ -n "$path" ]] || continue
        local_path="${LOCAL_DIR%/}/$path"
        backup_path="${BACKUP_DIR%/}/$path"

        if [[ ! -f "$local_path" ]]; then
            log "SKIP: localなし: $path"
            ((SKIPPED_VIDEO_COUNT+=1))
            continue
        fi
        if [[ ! -f "$backup_path" ]]; then
            log "SKIP: backupなし: $path"
            ((SKIPPED_VIDEO_COUNT+=1))
            continue
        fi

        local_size=$(stat -c '%s' "$local_path")
        backup_size=$(stat -c '%s' "$backup_path")
        if [[ "$size" != "$local_size" || "$size" != "$backup_size" ]]; then
            log "SKIP: サイズ不一致: $path remote=$size local=$local_size backup=$backup_size"
            ((SKIPPED_VIDEO_COUNT+=1))
            continue
        fi

        printf '%s\n' "$path" >> "$VERIFIED_FILE"
    done < <(jq -r '.[] | select(.IsDir != true) | [.Path, (.Size|tostring)] | @tsv' "$remote_json")

    rm -f "$remote_json" "$filter_file"
    VERIFIED_COUNT=$(wc -l < "$VERIFIED_FILE" | tr -d ' ')
    log "確認済み動画数: ${VERIFIED_COUNT}"
    log "削除スキップ動画数: ${SKIPPED_VIDEO_COUNT}"
}

delete_verified_videos() {
    if [[ "$NO_DELETE" == "true" ]]; then
        log "--no-delete 指定のため削除フェーズをスキップします"
        return 0
    fi

    build_verified_file_list
    if [[ "$VERIFIED_COUNT" -eq 0 ]]; then
        log "確認済み動画がないため削除コマンドを実行しません"
        return 0
    fi

    local common=()
    mapfile -d '' -t common < <(rclone_common_args)

    CURRENT_STEP="delete dry-run"
    log "クラウド動画削除 dry-run 開始: $VERIFIED_FILE"
    rclone delete "$REMOTE_SOURCE" \
        --dry-run \
        --files-from "$VERIFIED_FILE" \
        "${common[@]}" | tee "$DRY_RUN_LOG"
    log "クラウド動画削除 dry-run 完了: $DRY_RUN_LOG"

    CURRENT_STEP="delete remote videos"
    log "クラウド動画削除開始: $VERIFIED_FILE"
    rclone delete "$REMOTE_SOURCE" \
        --files-from "$VERIFIED_FILE" \
        "${common[@]}"
    DELETED_COUNT="$VERIFIED_COUNT"
    log "クラウド動画削除完了: ${DELETED_COUNT} 件"
}

main() {
    log "=== rclone メディア同期開始 ==="
    log "REMOTE_SOURCE=${REMOTE_SOURCE}"
    log "LOCAL_DIR=${LOCAL_DIR}"
    log "BACKUP_DIR=${BACKUP_DIR}"
    log "BACKUP_ROOT=${BACKUP_ROOT}"
    log "NO_DELETE=${NO_DELETE}"

    assert_prerequisites

    CURRENT_STEP="image copy"
    run_rclone_copy "画像" "$REMOTE_SOURCE" "$LOCAL_DIR" "${IMAGE_FILTERS[@]}"
    IMAGE_COPY_STATUS="succeeded"

    CURRENT_STEP="video copy"
    run_rclone_copy "動画" "$REMOTE_SOURCE" "$LOCAL_DIR" "${VIDEO_FILTERS[@]}"
    VIDEO_COPY_STATUS="succeeded"

    CURRENT_STEP="backup copy"
    run_rclone_copy "バックアップ" "$LOCAL_DIR" "$BACKUP_DIR" "${MEDIA_FILTERS[@]}"
    BACKUP_STATUS="succeeded"

    delete_verified_videos

    log "=== rclone メディア同期完了 ==="
}

main
