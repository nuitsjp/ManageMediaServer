#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

MEDIA_BACKUP_ENV="${MEDIA_BACKUP_ENV:-${REPO_ROOT}/config/env/media-backup.env}"
NOTIFICATION_ENV="${NOTIFICATION_ENV:-${REPO_ROOT}/config/env/notification.env}"

BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backup}"
LOG_DIR="${LOG_DIR:-/mnt/data/config/media-backup/logs}"
LOG_FILE="${LOG_FILE:-}"
LOCK_FILE="${LOCK_FILE:-}"
BACKUP_MIN_FREE_KIB="${BACKUP_MIN_FREE_KIB:-1048576}"

IMMICH_UPLOAD_SOURCE="${IMMICH_UPLOAD_SOURCE:-/mnt/data/immich/upload}"
IMMICH_UPLOAD_BACKUP="${IMMICH_UPLOAD_BACKUP:-/mnt/backup/immich-upload}"
IMMICH_EXTERNAL_SOURCE="${IMMICH_EXTERNAL_SOURCE:-/mnt/data/immich/external}"
IMMICH_EXTERNAL_BACKUP="${IMMICH_EXTERNAL_BACKUP:-/mnt/backup/immich-backup}"
JELLYFIN_MEDIA_SOURCE="${JELLYFIN_MEDIA_SOURCE:-/mnt/data/jellyfin/music-videos}"
JELLYFIN_MEDIA_BACKUP="${JELLYFIN_MEDIA_BACKUP:-/mnt/backup/jellyfin-backup}"

DRY_RUN=false
CURRENT_STEP="initializing"
COPIED_TARGETS=()

usage() {
    cat <<'USAGE'
Usage: media-backup.sh [--dry-run]

Copies media files to a physically separate backup drive without deleting
anything from the backup destination.

Options:
  --dry-run  Show what would be copied without writing files.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
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

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$1" | tee -a "$LOG_FILE"
}

load_env_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$file"
        set +a
    fi
}

load_env_file "$MEDIA_BACKUP_ENV"
load_env_file "$NOTIFICATION_ENV"

LOG_FILE="${LOG_FILE:-${LOG_DIR}/media-backup.log}"
mkdir -p "$LOG_DIR"
LOCK_FILE="${LOCK_FILE:-${LOG_DIR}/media-backup.lock}"

notify_discord() {
    local status="$1"
    local message="$2"

    if [[ "${NOTIFICATION_ENABLED:-false}" != "true" ]]; then
        log "Discord notification is disabled"
        return 0
    fi

    if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
        log "WARNING: DISCORD_WEBHOOK_URL is empty; skipping notification"
        return 0
    fi

    if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
        log "WARNING: curl or jq is missing; skipping notification"
        return 0
    fi

    local host now targets payload
    host=$(hostname)
    now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    targets=$(printf '%s\n' "${COPIED_TARGETS[@]:-none}" | sed '/^$/d' | paste -sd ', ' -)
    [[ -n "$targets" ]] || targets="none"

    payload=$(jq -n \
        --arg status "$status" \
        --arg host "$host" \
        --arg now "$now" \
        --arg message "$message" \
        --arg dry_run "$DRY_RUN" \
        --arg targets "$targets" \
        --arg log_file "$LOG_FILE" \
        '{content: ("**media backup " + $status + "**\n"
            + "host: `" + $host + "`\n"
            + "time: `" + $now + "`\n"
            + "message: " + $message + "\n"
            + "dry-run: `" + $dry_run + "`\n"
            + "targets: `" + $targets + "`\n"
            + "log: `" + $log_file + "`")}')

    if ! curl -fsS -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null; then
        log "WARNING: Discord notification failed"
    fi
}

on_exit() {
    local exit_code=$?
    trap - EXIT
    if [[ $exit_code -eq 0 ]]; then
        notify_discord "succeeded" "media backup completed"
    else
        notify_discord "failed" "failed at step: ${CURRENT_STEP}"
    fi
    exit "$exit_code"
}

trap on_exit EXIT

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
        log "ERROR: cannot check free space: ${path}"
        exit 1
    fi
    if (( available_kib < min_free_kib )); then
        log "ERROR: ${label} free space is too low: path=${path} available=${available_kib}KiB required=${min_free_kib}KiB"
        exit 1
    fi
    log "${label} free space OK: path=${path} available=${available_kib}KiB required=${min_free_kib}KiB"
}

assert_prerequisites() {
    CURRENT_STEP="preflight"
    command -v rclone >/dev/null || { log "ERROR: rclone is not installed"; exit 1; }

    if ! mountpoint -q "$BACKUP_ROOT"; then
        log "ERROR: backup root is not mounted: $BACKUP_ROOT"
        exit 1
    fi

    if [[ ! -w "$BACKUP_ROOT" ]]; then
        log "ERROR: backup root is not writable: $BACKUP_ROOT"
        exit 1
    fi

    assert_min_free_kib "backup root" "$BACKUP_ROOT" "$BACKUP_MIN_FREE_KIB"
}

copy_media_dir() {
    local label="$1"
    local source="$2"
    local destination="$3"

    CURRENT_STEP="copy ${label}"

    if [[ ! -d "$source" ]]; then
        log "ERROR: source directory is missing: $source"
        exit 1
    fi

    mkdir -p "$destination"

    local args=(
        copy
        "$source"
        "$destination"
        --create-empty-src-dirs
        --log-file "$LOG_FILE"
        --log-level INFO
    )

    if [[ "$DRY_RUN" == "true" ]]; then
        args+=(--dry-run)
    fi

    log "${label} backup start: ${source} -> ${destination}"
    rclone "${args[@]}"
    log "${label} backup done"
    COPIED_TARGETS+=("$label")
}

main() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "ERROR: another media backup is already running"
        exit 1
    fi

    log "=== media backup start ==="
    log "BACKUP_ROOT=${BACKUP_ROOT}"
    log "DRY_RUN=${DRY_RUN}"

    assert_prerequisites

    copy_media_dir "immich-upload" "$IMMICH_UPLOAD_SOURCE" "$IMMICH_UPLOAD_BACKUP"
    copy_media_dir "immich-external" "$IMMICH_EXTERNAL_SOURCE" "$IMMICH_EXTERNAL_BACKUP"
    copy_media_dir "jellyfin-media" "$JELLYFIN_MEDIA_SOURCE" "$JELLYFIN_MEDIA_BACKUP"

    log "=== media backup completed ==="
}

main
