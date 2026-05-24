#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

MEDIA_HEALTH_CHECK_ENV="${MEDIA_HEALTH_CHECK_ENV:-${REPO_ROOT}/config/env/media-health-check.env}"
NOTIFICATION_ENV="${NOTIFICATION_ENV:-${REPO_ROOT}/config/env/notification.env}"

NO_NOTIFY=false
FAILURES=()
CHECK_RESULTS=()

usage() {
    cat <<'USAGE'
Usage: media-health-check.sh [--no-notify]

Checks Immich/Jellyfin HTTP health, Docker Compose container state,
rclone-media-sync.timer, and filesystem free space.

Options:
  --no-notify  Run checks without sending Discord notifications.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-notify)
            NO_NOTIFY=true
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

load_env_file "$MEDIA_HEALTH_CHECK_ENV"
load_env_file "$NOTIFICATION_ENV"

PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"
LOG_DIR="${LOG_DIR:-/mnt/data/config/media-health-check/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/media-health-check.log}"
LOCK_FILE="${LOCK_FILE:-${LOG_DIR}/media-health-check.lock}"

IMMICH_COMPOSE_DIR="${IMMICH_COMPOSE_DIR:-${PROD_ROOT}/docker/immich}"
JELLYFIN_COMPOSE_DIR="${JELLYFIN_COMPOSE_DIR:-${PROD_ROOT}/docker/jellyfin}"

IMMICH_HEALTH_URL="${IMMICH_HEALTH_URL:-http://127.0.0.1:2283}"
JELLYFIN_HEALTH_URL="${JELLYFIN_HEALTH_URL:-http://127.0.0.1:8096}"
HTTP_MAX_TIME_SECONDS="${HTTP_MAX_TIME_SECONDS:-10}"

RCLONE_TIMER="${RCLONE_TIMER:-rclone-media-sync.timer}"
REQUIRE_RCLONE_TIMER_ENABLED="${REQUIRE_RCLONE_TIMER_ENABLED:-true}"

ROOT_PATH="${ROOT_PATH:-/}"
DATA_PATH="${DATA_PATH:-/mnt/data}"
BACKUP_PATH="${BACKUP_PATH:-/mnt/backup}"
ROOT_MIN_FREE_KIB="${ROOT_MIN_FREE_KIB:-1048576}"
DATA_MIN_FREE_KIB="${DATA_MIN_FREE_KIB:-1048576}"
BACKUP_MIN_FREE_KIB="${BACKUP_MIN_FREE_KIB:-1048576}"
REQUIRE_BACKUP_MOUNT="${REQUIRE_BACKUP_MOUNT:-true}"

NOTIFY_ON_SUCCESS="${NOTIFY_ON_SUCCESS:-false}"

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

record_ok() {
    local message="$1"
    CHECK_RESULTS+=("OK ${message}")
    log "OK: ${message}"
}

record_failure() {
    local message="$1"
    FAILURES+=("$message")
    CHECK_RESULTS+=("FAIL ${message}")
    log "ERROR: ${message}"
}

notify_discord() {
    local status="$1"
    local message="$2"

    if [[ "$NO_NOTIFY" == "true" ]]; then
        log "Discord notification skipped by --no-notify"
        return 0
    fi

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

    local host now failures results payload
    host=$(hostname)
    now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    failures=$(join_items '; ' "${FAILURES[@]}")
    results=$(join_items '; ' "${CHECK_RESULTS[@]}")
    [[ -n "$failures" ]] || failures="none"
    [[ -n "$results" ]] || results="none"

    payload=$(jq -n \
        --arg status "$status" \
        --arg host "$host" \
        --arg now "$now" \
        --arg message "$message" \
        --arg failures "$failures" \
        --arg results "$results" \
        --arg log_file "$LOG_FILE" \
        '{content: ("**media health check " + $status + "**\n"
            + "host: `" + $host + "`\n"
            + "time: `" + $now + "`\n"
            + "message: " + $message + "\n"
            + "failures: `" + $failures + "`\n"
            + "results: `" + $results + "`\n"
            + "log: `" + $log_file + "`")}')

    if ! curl -fsS -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null; then
        log "WARNING: Discord notification failed"
    fi
}

check_command() {
    local command_name="$1"
    if command -v "$command_name" >/dev/null; then
        record_ok "command exists: ${command_name}"
        return 0
    fi

    record_failure "command is missing: ${command_name}"
    return 1
}

check_http() {
    local label="$1"
    local url="$2"
    local http_code

    if ! command -v curl >/dev/null; then
        record_failure "${label} HTTP check skipped because curl is missing"
        return
    fi

    if http_code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time "$HTTP_MAX_TIME_SECONDS" "$url"); then
        record_ok "${label} HTTP healthy: url=${url} status=${http_code}"
    else
        record_failure "${label} HTTP failed: url=${url}"
    fi
}

check_compose() {
    local label="$1"
    local compose_dir="$2"
    local compose_file="${compose_dir}/docker-compose.yml"
    local services running_services missing_services service

    if [[ ! -f "$compose_file" ]]; then
        record_failure "${label} compose file is missing: ${compose_file}"
        return
    fi

    if ! command -v docker >/dev/null; then
        record_failure "${label} compose check skipped because docker is missing"
        return
    fi

    if ! services=$(docker compose -f "$compose_file" config --services 2>&1); then
        record_failure "${label} compose config failed: ${services}"
        return
    fi

    if ! running_services=$(docker compose -f "$compose_file" ps --services --filter status=running 2>&1); then
        record_failure "${label} compose ps failed: ${running_services}"
        return
    fi

    missing_services=()
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        if ! grep -Fxq "$service" <<<"$running_services"; then
            missing_services+=("$service")
        fi
    done <<<"$services"

    if (( ${#missing_services[@]} > 0 )); then
        record_failure "${label} compose services not running: $(join_items ', ' "${missing_services[@]}")"
    else
        record_ok "${label} compose services running: $(join_items ', ' $services)"
    fi
}

check_timer() {
    local timer="$1"
    local state

    if ! command -v systemctl >/dev/null; then
        record_failure "${timer} check skipped because systemctl is missing"
        return
    fi

    if systemctl is-active --quiet "$timer"; then
        record_ok "${timer} is active"
    else
        state=$(systemctl is-active "$timer" 2>/dev/null || true)
        record_failure "${timer} is not active: ${state:-unknown}"
    fi

    if [[ "$REQUIRE_RCLONE_TIMER_ENABLED" == "true" ]]; then
        if systemctl is-enabled --quiet "$timer"; then
            record_ok "${timer} is enabled"
        else
            state=$(systemctl is-enabled "$timer" 2>/dev/null || true)
            record_failure "${timer} is not enabled: ${state:-unknown}"
        fi
    fi
}

available_kib_for_path() {
    df -Pk "$1" | awk 'NR == 2 {print $4}'
}

check_free_space() {
    local label="$1"
    local path="$2"
    local min_free_kib="$3"
    local available_kib

    if [[ ! -e "$path" ]]; then
        record_failure "${label} path is missing: ${path}"
        return
    fi

    if ! available_kib=$(available_kib_for_path "$path"); then
        record_failure "${label} free space check failed: ${path}"
        return
    fi

    if [[ -z "$available_kib" ]]; then
        record_failure "${label} free space check returned no value: ${path}"
        return
    fi

    if (( available_kib < min_free_kib )); then
        record_failure "${label} free space is too low: path=${path} available=${available_kib}KiB required=${min_free_kib}KiB"
    else
        record_ok "${label} free space OK: path=${path} available=${available_kib}KiB required=${min_free_kib}KiB"
    fi
}

main() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "ERROR: another media health check is already running"
        exit 1
    fi

    log "=== media health check start ==="

    check_command curl || true
    check_command docker || true
    check_command systemctl || true
    check_command df || true

    check_http "Immich" "$IMMICH_HEALTH_URL"
    check_http "Jellyfin" "$JELLYFIN_HEALTH_URL"
    check_compose "Immich" "$IMMICH_COMPOSE_DIR"
    check_compose "Jellyfin" "$JELLYFIN_COMPOSE_DIR"
    check_timer "$RCLONE_TIMER"

    if [[ "$REQUIRE_BACKUP_MOUNT" == "true" ]]; then
        if mountpoint -q "$BACKUP_PATH"; then
            record_ok "backup path is mounted: ${BACKUP_PATH}"
        else
            record_failure "backup path is not mounted: ${BACKUP_PATH}"
        fi
    fi

    check_free_space "root" "$ROOT_PATH" "$ROOT_MIN_FREE_KIB"
    check_free_space "data" "$DATA_PATH" "$DATA_MIN_FREE_KIB"
    check_free_space "backup" "$BACKUP_PATH" "$BACKUP_MIN_FREE_KIB"

    if (( ${#FAILURES[@]} > 0 )); then
        notify_discord "failed" "one or more health checks failed"
        log "=== media health check failed ==="
        return 1
    fi

    if [[ "$NOTIFY_ON_SUCCESS" == "true" ]]; then
        notify_discord "succeeded" "all health checks passed"
    fi

    log "=== media health check completed ==="
}

main
