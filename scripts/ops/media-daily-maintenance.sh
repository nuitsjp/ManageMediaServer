#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

MEDIA_DAILY_ENV="${MEDIA_DAILY_ENV:-${REPO_ROOT}/config/env/media-daily-maintenance.env}"
NOTIFICATION_ENV="${NOTIFICATION_ENV:-${REPO_ROOT}/config/env/notification.env}"

DRY_RUN=false
CHECK_ONLY=false
PREFLIGHT_ONLY=false
CURRENT_STEP="initializing"
START_EPOCH=$(date +%s)
SUMMARY_DIR=""

usage() {
    cat <<'USAGE'
Usage: media-daily-maintenance.sh [--dry-run] [--check-only] [--preflight]

Runs the daily media-server maintenance workflow with one Discord summary.
Each step runs independently; failures are collected and reported together.

Options:
  --dry-run     Run safe dry-run/check modes where available.
  --check-only  Check versions and pending OS updates without running mutating steps.
  --preflight   Verify that every enabled step can start, then exit without
                running steps or sending a notification.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --preflight)
            PREFLIGHT_ONLY=true
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

load_env_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$file"
        set +a
    fi
}

load_env_file "$MEDIA_DAILY_ENV"
load_env_file "$NOTIFICATION_ENV"

PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"
LOG_DIR="${LOG_DIR:-/mnt/data/config/media-daily-maintenance/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/media-daily-maintenance.log}"
LOCK_FILE="${LOCK_FILE:-${LOG_DIR}/media-daily-maintenance.lock}"
CHILD_USER="${CHILD_USER:-mediaserver}"

RUN_MEDIA_BACKUP="${RUN_MEDIA_BACKUP:-true}"
RUN_MEDIA_APP_UPDATE="${RUN_MEDIA_APP_UPDATE:-true}"
RUN_TOKEN_MONITOR_UPDATE="${RUN_TOKEN_MONITOR_UPDATE:-true}"
RUN_RCLONE_SYNC="${RUN_RCLONE_SYNC:-true}"
RUN_OS_UPDATE="${RUN_OS_UPDATE:-true}"
RCLONE_SYNC_NO_DELETE="${RCLONE_SYNC_NO_DELETE:-false}"

AUTO_REBOOT="${AUTO_REBOOT:-true}"
AUTO_REBOOT_DELAY_MINUTES="${AUTO_REBOOT_DELAY_MINUTES:-5}"

MEDIA_BACKUP_SCRIPT="${MEDIA_BACKUP_SCRIPT:-${PROD_ROOT}/scripts/ops/media-backup.sh}"
MEDIA_APP_UPDATE_SCRIPT="${MEDIA_APP_UPDATE_SCRIPT:-${PROD_ROOT}/scripts/ops/media-app-update.sh}"
TOKEN_MONITOR_UPDATE_SCRIPT="${TOKEN_MONITOR_UPDATE_SCRIPT:-${PROD_ROOT}/token-monitor/scripts/update.sh}"
RCLONE_MEDIA_SYNC_SCRIPT="${RCLONE_MEDIA_SYNC_SCRIPT:-${PROD_ROOT}/scripts/ops/rclone-media-sync.sh}"
MEDIA_OS_UPDATE_SCRIPT="${MEDIA_OS_UPDATE_SCRIPT:-${PROD_ROOT}/scripts/ops/media-os-update.sh}"

MEDIA_BACKUP_STATUS="skipped"
MEDIA_APP_UPDATE_STATUS="skipped"
TOKEN_MONITOR_UPDATE_STATUS="skipped"
RCLONE_SYNC_STATUS="skipped"
MEDIA_OS_UPDATE_STATUS="skipped"
MEDIA_BACKUP_FAILED=false
DAILY_RESULT="succeeded"
FAILED_STEPS=()
FAILED_MESSAGES=()
REBOOT_ACTION="not_required"

mkdir -p "$LOG_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$1" | tee -a "$LOG_FILE"
}

join_items() {
    local separator="$1"
    shift || true
    local output=""
    local item
    for item in "$@"; do
        if [[ -z "$output" ]]; then
            output="$item"
        else
            output="${output}${separator}${item}"
        fi
    done
    printf '%s' "$output"
}

duration_text() {
    local seconds="$1"
    local hours minutes
    hours=$((seconds / 3600))
    minutes=$(((seconds % 3600) / 60))
    seconds=$((seconds % 60))
    if (( hours > 0 )); then
        printf '%dh %02dm %02ds' "$hours" "$minutes" "$seconds"
    elif (( minutes > 0 )); then
        printf '%dm %02ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}

status_word() {
    case "${1:-skipped}" in
        succeeded|updated|major-update-detected) printf 'ok' ;;
        skipped*) printf 'skipped' ;;
        failed) printf 'failed' ;;
        *) printf '%s' "$1" ;;
    esac
}

summary_value() {
    local name="$1"
    local default="${2:-unknown}"
    printf '%s' "${!name:-$default}"
}

source_summary() {
    local file="$1"
    if [[ -f "$file" ]]; then
        # shellcheck disable=SC1090
        source "$file"
    fi
}

run_as_child_user() {
    if [[ "${EUID}" -eq 0 && -n "$CHILD_USER" && "$CHILD_USER" != "root" ]] && id "$CHILD_USER" >/dev/null 2>&1; then
        runuser -u "$CHILD_USER" -- "$@"
    else
        "$@"
    fi
}

mark_failed() {
    local step="$1"
    local message="$2"
    DAILY_RESULT="failed"
    FAILED_STEPS+=("$step")
    FAILED_MESSAGES+=("${step}: ${message}")
    log "ERROR: ${step}: ${message}"
}

missing_files() {
    local file
    for file in "$@"; do
        [[ -f "$file" ]] || printf '%s\n' "$file"
    done
}

token_monitor_required_files() {
    local token_root
    token_root=$(cd "$(dirname "$TOKEN_MONITOR_UPDATE_SCRIPT")/.." 2>/dev/null && pwd) || token_root="$(dirname "$TOKEN_MONITOR_UPDATE_SCRIPT")/.."
    printf '%s\n' \
        "$TOKEN_MONITOR_UPDATE_SCRIPT" \
        "${token_root}/scripts/backup-data.sh" \
        "${token_root}/scripts/build-image.sh" \
        "${token_root}/scripts/healthcheck.sh" \
        "${token_root}/compose.yaml" \
        "${token_root}/Dockerfile" \
        "${PROD_ROOT}/config/env/token-monitor-deploy.env" \
        "${PROD_ROOT}/config/env/token-monitor-common.env"
}

# Prints the files a step needs that are missing. Empty output means the step can start.
step_missing_files() {
    case "$1" in
        media-backup) missing_files "$MEDIA_BACKUP_SCRIPT" ;;
        media-app-update) missing_files "$MEDIA_APP_UPDATE_SCRIPT" ;;
        token-monitor-update)
            local files=()
            mapfile -t files < <(token_monitor_required_files)
            missing_files "${files[@]}"
            ;;
        rclone-media-sync) missing_files "$RCLONE_MEDIA_SYNC_SCRIPT" ;;
        os-update) missing_files "$MEDIA_OS_UPDATE_SCRIPT" ;;
    esac
}

# Returns non-zero and records a failure when a step's files are missing.
require_step_files() {
    local step_id="$1"
    local step_name="$2"
    local missing=()
    mapfile -t missing < <(step_missing_files "$step_id")
    (( ${#missing[@]} == 0 )) && return 0
    mark_failed "$step_name" "missing file: $(join_items ', ' "${missing[@]}")"
    return 1
}

run_media_backup() {
    [[ "$RUN_MEDIA_BACKUP" == "true" ]] || return 0
    CURRENT_STEP="media backup"
    if ! require_step_files media-backup "$CURRENT_STEP"; then
        MEDIA_BACKUP_STATUS="failed"
        MEDIA_BACKUP_FAILED=true
        return 1
    fi
    local summary="${SUMMARY_DIR}/media-backup.env"
    local args=()
    if [[ "$DRY_RUN" == "true" || "$CHECK_ONLY" == "true" ]]; then
        args+=(--dry-run)
    fi

    log "media backup start"
    MEDIA_BACKUP_STATUS=""
    if run_as_child_user env SUPPRESS_DISCORD=true SUMMARY_FILE="$summary" /usr/bin/bash "$MEDIA_BACKUP_SCRIPT" "${args[@]}"; then
        source_summary "$summary"
        MEDIA_BACKUP_STATUS="${MEDIA_BACKUP_STATUS:-succeeded}"
        log "media backup completed: ${MEDIA_BACKUP_STATUS}"
    else
        source_summary "$summary"
        MEDIA_BACKUP_STATUS="${MEDIA_BACKUP_STATUS:-failed}"
        MEDIA_BACKUP_FAILED=true
        mark_failed "media backup" "${MEDIA_BACKUP_MESSAGE:-media backup failed}"
        return 1
    fi
}

run_media_app_update() {
    [[ "$RUN_MEDIA_APP_UPDATE" == "true" ]] || return 0
    # The app update skips its own backup check because this workflow just ran
    # media backup, so it must not proceed when that backup failed.
    if [[ "$MEDIA_BACKUP_FAILED" == "true" ]]; then
        MEDIA_APP_UPDATE_STATUS="skipped_backup_failed"
        log "media backup failed; skipping media app update"
        return 0
    fi
    CURRENT_STEP="media app update"
    if ! require_step_files media-app-update "$CURRENT_STEP"; then
        MEDIA_APP_UPDATE_STATUS="failed"
        return 1
    fi
    local summary="${SUMMARY_DIR}/media-app-update.env"
    local args=(--skip-backup-check)
    if [[ "$CHECK_ONLY" == "true" ]]; then
        args=(--check-only)
    elif [[ "$DRY_RUN" == "true" ]]; then
        args+=(--dry-run)
    fi

    log "media app update start"
    MEDIA_APP_UPDATE_STATUS=""
    if run_as_child_user env SUPPRESS_DISCORD=true SUMMARY_FILE="$summary" /usr/bin/bash "$MEDIA_APP_UPDATE_SCRIPT" "${args[@]}"; then
        source_summary "$summary"
        MEDIA_APP_UPDATE_STATUS="${MEDIA_APP_UPDATE_STATUS:-succeeded}"
        log "media app update completed: ${MEDIA_APP_UPDATE_STATUS}"
    else
        source_summary "$summary"
        MEDIA_APP_UPDATE_STATUS="${MEDIA_APP_UPDATE_STATUS:-failed}"
        mark_failed "media app update" "${MEDIA_APP_UPDATE_MESSAGE:-media app update failed}"
        return 1
    fi
}

run_token_monitor_update() {
    [[ "$RUN_TOKEN_MONITOR_UPDATE" == "true" ]] || return 0
    CURRENT_STEP="Token Monitor update"
    if ! require_step_files token-monitor-update "$CURRENT_STEP"; then
        TOKEN_MONITOR_UPDATE_STATUS="failed"
        return 1
    fi
    local summary="${SUMMARY_DIR}/token-monitor-update.env"
    local args=()
    if [[ "$CHECK_ONLY" == "true" ]]; then
        args+=(--check-only)
    elif [[ "$DRY_RUN" == "true" ]]; then
        args+=(--dry-run)
    fi

    log "Token Monitor update start"
    TOKEN_MONITOR_UPDATE_STATUS=""
    if run_as_child_user env SUMMARY_FILE="$summary" /usr/bin/bash "$TOKEN_MONITOR_UPDATE_SCRIPT" "${args[@]}"; then
        source_summary "$summary"
        TOKEN_MONITOR_UPDATE_STATUS="${TOKEN_MONITOR_UPDATE_STATUS:-succeeded}"
        log "Token Monitor update completed: ${TOKEN_MONITOR_UPDATE_STATUS}"
    else
        source_summary "$summary"
        TOKEN_MONITOR_UPDATE_STATUS="${TOKEN_MONITOR_UPDATE_STATUS:-failed}"
        mark_failed "Token Monitor update" "Token Monitor update failed"
        return 1
    fi
}

run_rclone_sync() {
    [[ "$RUN_RCLONE_SYNC" == "true" ]] || return 0
    if [[ "$CHECK_ONLY" == "true" ]]; then
        RCLONE_SYNC_STATUS="skipped_check_only"
        log "check-only mode; skipping rclone media sync"
        return 0
    fi

    CURRENT_STEP="rclone media sync"
    if ! require_step_files rclone-media-sync "$CURRENT_STEP"; then
        RCLONE_SYNC_STATUS="failed"
        return 1
    fi
    local summary="${SUMMARY_DIR}/rclone-media-sync.env"
    local args=()
    if [[ "$DRY_RUN" == "true" ]]; then
        args+=(--dry-run)
    fi
    if [[ "$RCLONE_SYNC_NO_DELETE" == "true" ]]; then
        args+=(--no-delete)
    fi

    log "rclone media sync start"
    RCLONE_SYNC_STATUS=""
    if run_as_child_user env SUPPRESS_DISCORD=true SUMMARY_FILE="$summary" /usr/bin/bash "$RCLONE_MEDIA_SYNC_SCRIPT" "${args[@]}"; then
        source_summary "$summary"
        RCLONE_SYNC_STATUS="${RCLONE_SYNC_STATUS:-succeeded}"
        log "rclone media sync completed: ${RCLONE_SYNC_STATUS}"
    else
        source_summary "$summary"
        RCLONE_SYNC_STATUS="${RCLONE_SYNC_STATUS:-failed}"
        mark_failed "rclone media sync" "${RCLONE_SYNC_MESSAGE:-rclone media sync failed}"
        return 1
    fi
}

run_os_update() {
    [[ "$RUN_OS_UPDATE" == "true" ]] || return 0
    CURRENT_STEP="os update"
    if ! require_step_files os-update "$CURRENT_STEP"; then
        MEDIA_OS_UPDATE_STATUS="failed"
        return 1
    fi
    local summary="${SUMMARY_DIR}/media-os-update.env"
    local args=()
    if [[ "$CHECK_ONLY" == "true" ]]; then
        args+=(--check-only)
    elif [[ "$DRY_RUN" == "true" ]]; then
        args+=(--dry-run)
    fi

    log "OS update start"
    MEDIA_OS_UPDATE_STATUS=""
    if env SUMMARY_FILE="$summary" /usr/bin/bash "$MEDIA_OS_UPDATE_SCRIPT" "${args[@]}"; then
        source_summary "$summary"
        MEDIA_OS_UPDATE_STATUS="${MEDIA_OS_UPDATE_STATUS:-succeeded}"
        log "OS update completed: ${MEDIA_OS_UPDATE_STATUS}"
    else
        source_summary "$summary"
        MEDIA_OS_UPDATE_STATUS="${MEDIA_OS_UPDATE_STATUS:-failed}"
        mark_failed "os update" "${MEDIA_OS_UPDATE_MESSAGE:-OS update failed}"
        return 1
    fi
}

storage_line() {
    local path="$1"
    if [[ -e "$path" ]]; then
        df -h "$path" | awk -v path="$path" 'NR == 2 {printf "- `%s`: `%s free / %s used`\n", path, $4, $5}'
    else
        printf -- '- `%s`: `missing`\n' "$path"
    fi
}

build_notification_body() {
    local host now duration title warnings=()
    host=$(hostname)
    now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    duration=$(duration_text "$(($(date +%s) - START_EPOCH))")

    if [[ "${MEDIA_APP_MAJOR_UPDATES:-none}" != "none" ]]; then
        warnings+=("app major update detected: ${MEDIA_APP_MAJOR_UPDATES}")
    fi
    if [[ "${RCLONE_SKIPPED_VIDEO_COUNT:-0}" != "0" ]]; then
        warnings+=("rclone skipped videos: ${RCLONE_SKIPPED_VIDEO_COUNT}")
    fi

    if [[ "$DAILY_RESULT" == "failed" ]]; then
        title="media daily maintenance failed"
    elif [[ "${MEDIA_OS_REBOOT_REQUIRED:-no}" == "yes" && "$AUTO_REBOOT" == "true" && "$CHECK_ONLY" != "true" && "$DRY_RUN" != "true" ]]; then
        title="media daily maintenance completed; reboot scheduled"
    elif (( ${#warnings[@]} > 0 )); then
        title="media daily maintenance completed with warnings"
    else
        title="media daily maintenance succeeded"
    fi

    {
        printf '**%s**\n\n' "$title"
        printf 'host: `%s`\n' "$host"
        printf 'time: `%s`\n' "$now"
        printf 'duration: `%s`\n' "$duration"
        printf 'result: `%s`\n' "$DAILY_RESULT"
        if [[ "$DAILY_RESULT" == "failed" ]]; then
            printf 'failed steps: `%s`\n' "$(join_items ', ' "${FAILED_STEPS[@]}")"
            local failure
            for failure in "${FAILED_MESSAGES[@]}"; do
                printf -- '- %s\n' "$failure"
            done
        fi
        printf '\nsteps:\n'
        printf -- '- media backup: `%s`\n' "$(status_word "$MEDIA_BACKUP_STATUS")"
        printf -- '- app update: `%s`\n' "$(status_word "$MEDIA_APP_UPDATE_STATUS")"
        printf -- '- Token Monitor update: `%s`\n' "$(status_word "$TOKEN_MONITOR_UPDATE_STATUS")"
        printf -- '- rclone sync: `%s`\n' "$(status_word "$RCLONE_SYNC_STATUS")"
        printf -- '- os update: `%s`\n' "$(status_word "$MEDIA_OS_UPDATE_STATUS")"
        printf -- '- reboot: `%s`\n' "$REBOOT_ACTION"

        printf '\nsync:\n'
        printf -- '- image copy: `%s`\n' "$(summary_value RCLONE_IMAGE_COPY_STATUS "${RCLONE_SYNC_STATUS}")"
        printf -- '- video copy: `%s`\n' "$(summary_value RCLONE_VIDEO_COPY_STATUS "${RCLONE_SYNC_STATUS}")"
        printf -- '- sync backup: `%s`\n' "$(summary_value RCLONE_BACKUP_STATUS "${RCLONE_SYNC_STATUS}")"
        printf -- '- verified videos: `%s`\n' "$(summary_value RCLONE_VERIFIED_COUNT 0)"
        printf -- '- deleted videos: `%s`\n' "$(summary_value RCLONE_DELETED_COUNT 0)"
        printf -- '- skipped videos: `%s`\n' "$(summary_value RCLONE_SKIPPED_VIDEO_COUNT 0)"
        printf -- '- dry-run: `%s`\n' "$(summary_value RCLONE_DRY_RUN "$DRY_RUN")"
        printf -- '- no-delete: `%s`\n' "$(summary_value RCLONE_NO_DELETE "$RCLONE_SYNC_NO_DELETE")"

        printf '\nbackup:\n'
        printf -- '- targets: `%s`\n' "$(summary_value MEDIA_BACKUP_TARGETS none)"

        printf '\napp updates:\n'
        printf -- '- latest: `%s`\n' "$(summary_value MEDIA_APP_LATEST_VERSIONS unknown)"
        printf -- '- updated containers: `%s`\n' "$(summary_value MEDIA_APP_UPDATED_CONTAINERS none)"
        printf -- '- major updates: `%s`\n' "$(summary_value MEDIA_APP_MAJOR_UPDATES none)"

        printf '\nToken Monitor:\n'
        printf -- '- current: `%s`\n' "$(summary_value TOKEN_MONITOR_CURRENT_VERSION unknown)"
        printf -- '- latest: `%s`\n' "$(summary_value TOKEN_MONITOR_LATEST_VERSION unknown)"
        printf -- '- updated: `%s`\n' "$(summary_value TOKEN_MONITOR_UPDATED_VERSION none)"

        printf '\nos updates:\n'
        printf -- '- apt upgraded: `%s`\n' "$(summary_value MEDIA_OS_APT_UPGRADED_PACKAGES none)"
        printf -- '- apt upgraded count: `%s`\n' "$(summary_value MEDIA_OS_APT_UPGRADED_COUNT 0)"
        printf -- '- snap refreshed: `%s`\n' "$(summary_value MEDIA_OS_SNAP_REFRESHED_PACKAGES none)"
        printf -- '- snap refreshed count: `%s`\n' "$(summary_value MEDIA_OS_SNAP_REFRESHED_COUNT 0)"
        printf -- '- autoremove: `%s`\n' "$(summary_value MEDIA_OS_AUTOREMOVE_STATUS not_run)"
        printf -- '- reboot required: `%s`\n' "$(summary_value MEDIA_OS_REBOOT_REQUIRED no)"
        printf -- '- reboot required by: `%s`\n' "$(summary_value MEDIA_OS_REBOOT_REQUIRED_PACKAGES none)"

        if (( ${#warnings[@]} > 0 )); then
            printf '\nwarnings:\n'
            local warning
            for warning in "${warnings[@]}"; do
                printf -- '- %s\n' "$warning"
            done
        fi

        printf '\nstorage:\n'
        storage_line "/"
        storage_line "/mnt/data"
        storage_line "/mnt/backup"

        printf '\nlogs:\n'
        printf -- '- daily: `%s`\n' "$LOG_FILE"
        printf -- '- backup: `%s`\n' "$(summary_value MEDIA_BACKUP_LOG_FILE /mnt/data/config/media-backup/logs/media-backup.log)"
        printf -- '- app update: `%s`\n' "$(summary_value MEDIA_APP_LOG_FILE /mnt/data/config/media-app-update/logs/media-app-update.log)"
        printf -- '- Token Monitor: `%s`\n' "$(summary_value TOKEN_MONITOR_UPDATE_LOG_FILE /mnt/data/token-monitor/update/logs/update.log)"
        printf -- '- sync: `%s`\n' "$(summary_value RCLONE_LOG_FILE /mnt/data/config/rclone/logs/media-sync.log)"
        printf -- '- os update: `%s`\n' "$(summary_value MEDIA_OS_LOG_FILE /mnt/data/config/media-os-update/logs/media-os-update.log)"
    }
}

notify_discord() {
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

    local body payload
    body=$(build_notification_body)
    payload=$(jq -n --arg content "$body" '{content: $content}')
    if ! curl -fsS -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null; then
        log "WARNING: Discord notification failed"
    fi
}

schedule_reboot_if_needed() {
    if [[ "$DAILY_RESULT" != "succeeded" ]]; then
        REBOOT_ACTION="not_attempted"
        return 0
    fi
    if [[ "${MEDIA_OS_REBOOT_REQUIRED:-no}" != "yes" ]]; then
        REBOOT_ACTION="not_required"
        return 0
    fi
    if [[ "$AUTO_REBOOT" != "true" || "$CHECK_ONLY" == "true" || "$DRY_RUN" == "true" ]]; then
        REBOOT_ACTION="required_not_scheduled"
        return 0
    fi
    if [[ "${EUID}" -ne 0 ]]; then
        REBOOT_ACTION="required_but_not_root"
        return 0
    fi

    REBOOT_ACTION="scheduled_in_${AUTO_REBOOT_DELAY_MINUTES}_minutes"
}

on_exit() {
    local exit_code=$?
    trap - EXIT

    if [[ $exit_code -ne 0 && "$DAILY_RESULT" != "failed" ]]; then
        mark_failed "$CURRENT_STEP" "unexpected failure"
    fi

    if [[ "$PREFLIGHT_ONLY" == "true" ]]; then
        exit "$exit_code"
    fi

    schedule_reboot_if_needed
    notify_discord

    if [[ "$REBOOT_ACTION" == scheduled_in_* ]]; then
        log "scheduling reboot in ${AUTO_REBOOT_DELAY_MINUTES} minutes"
        shutdown -r "+${AUTO_REBOOT_DELAY_MINUTES}" "ManageMediaServer daily maintenance completed; reboot required" \
            || log "WARNING: failed to schedule reboot"
    fi

    if [[ -n "$SUMMARY_DIR" ]]; then
        rm -rf "$SUMMARY_DIR"
    fi

    exit "$exit_code"
}

trap on_exit EXIT

assert_prerequisites() {
    CURRENT_STEP="preflight"
    command -v flock >/dev/null || { log "ERROR: flock is not installed"; exit 1; }
    command -v jq >/dev/null || { log "ERROR: jq is not installed"; exit 1; }
}

run_preflight() {
    assert_prerequisites

    local failed=false step_id enabled missing=()
    for step_id in media-backup media-app-update token-monitor-update rclone-media-sync os-update; do
        case "$step_id" in
            media-backup) enabled="$RUN_MEDIA_BACKUP" ;;
            media-app-update) enabled="$RUN_MEDIA_APP_UPDATE" ;;
            token-monitor-update) enabled="$RUN_TOKEN_MONITOR_UPDATE" ;;
            rclone-media-sync) enabled="$RUN_RCLONE_SYNC" ;;
            os-update) enabled="$RUN_OS_UPDATE" ;;
        esac
        if [[ "$enabled" != "true" ]]; then
            log "preflight: ${step_id}: disabled"
            continue
        fi
        mapfile -t missing < <(step_missing_files "$step_id")
        if (( ${#missing[@]} == 0 )); then
            log "preflight: ${step_id}: ok"
        else
            failed=true
            log "ERROR: preflight: ${step_id}: missing file: $(join_items ', ' "${missing[@]}")"
        fi
    done

    if [[ "$failed" == "true" ]]; then
        DAILY_RESULT="failed"
        exit 1
    fi
    log "preflight passed"
}

run_step() {
    local step="$1"
    # A failed step is already recorded by mark_failed; keep running the rest.
    "$step" || log "continuing after failed step: ${CURRENT_STEP}"
}

main() {
    if [[ "$PREFLIGHT_ONLY" == "true" ]]; then
        run_preflight
        exit 0
    fi

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "ERROR: another daily maintenance is already running"
        exit 1
    fi

    SUMMARY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/media-daily-maintenance.XXXXXX")
    chmod 0777 "$SUMMARY_DIR"

    log "=== media daily maintenance start ==="
    log "DRY_RUN=${DRY_RUN}"
    log "CHECK_ONLY=${CHECK_ONLY}"

    assert_prerequisites

    run_step run_media_backup
    run_step run_media_app_update
    run_step run_token_monitor_update
    run_step run_rclone_sync
    run_step run_os_update

    if [[ "$DAILY_RESULT" == "failed" ]]; then
        log "=== media daily maintenance completed with failures: $(join_items ', ' "${FAILED_STEPS[@]}") ==="
        exit 1
    fi
    log "=== media daily maintenance completed ==="
}

main
