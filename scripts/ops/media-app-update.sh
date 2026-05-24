#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

MEDIA_APP_UPDATE_ENV="${MEDIA_APP_UPDATE_ENV:-${REPO_ROOT}/config/env/media-app-update.env}"
NOTIFICATION_ENV="${NOTIFICATION_ENV:-${REPO_ROOT}/config/env/notification.env}"

DRY_RUN=false
CHECK_ONLY=false
SKIP_BACKUP_CHECK=false
CURRENT_STEP="initializing"
UPDATED_CONTAINERS=()
MAJOR_UPDATE_MESSAGES=()
LATEST_VERSION_SUMMARY=()
BEFORE_FILE=""
SUPPRESS_DISCORD="${SUPPRESS_DISCORD:-false}"
SUMMARY_FILE="${SUMMARY_FILE:-}"

usage() {
    cat <<'USAGE'
Usage: media-app-update.sh [--dry-run] [--check-only] [--skip-backup-check]

Checks for major Immich/Jellyfin releases, updates containers within the
configured major versions, verifies health, and sends a Discord notification.

Options:
  --dry-run            Check versions and show the update commands without running them.
  --check-only         Check upstream versions and major updates without pulling images.
  --skip-backup-check  Do not require the latest media-backup.service result to be successful.
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
        --skip-backup-check)
            SKIP_BACKUP_CHECK=true
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

load_env_file "$MEDIA_APP_UPDATE_ENV"
load_env_file "$NOTIFICATION_ENV"

PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backup}"
LOG_DIR="${LOG_DIR:-/mnt/data/config/media-app-update/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/media-app-update.log}"
LOCK_FILE="${LOCK_FILE:-${LOG_DIR}/media-app-update.lock}"

ROOT_MIN_FREE_KIB="${ROOT_MIN_FREE_KIB:-1048576}"
DATA_MIN_FREE_KIB="${DATA_MIN_FREE_KIB:-1048576}"
BACKUP_MIN_FREE_KIB="${BACKUP_MIN_FREE_KIB:-1048576}"

IMMICH_ALLOWED_MAJOR="${IMMICH_ALLOWED_MAJOR:-2}"
JELLYFIN_ALLOWED_MAJOR="${JELLYFIN_ALLOWED_MAJOR:-10}"

IMMICH_COMPOSE_DIR="${IMMICH_COMPOSE_DIR:-${PROD_ROOT}/docker/immich}"
JELLYFIN_COMPOSE_DIR="${JELLYFIN_COMPOSE_DIR:-${PROD_ROOT}/docker/jellyfin}"

IMMICH_HEALTH_URL="${IMMICH_HEALTH_URL:-http://127.0.0.1:2283}"
JELLYFIN_HEALTH_URL="${JELLYFIN_HEALTH_URL:-http://127.0.0.1:8096}"
HEALTH_RETRIES="${HEALTH_RETRIES:-12}"
HEALTH_RETRY_SLEEP_SECONDS="${HEALTH_RETRY_SLEEP_SECONDS:-10}"
REQUIRE_MEDIA_BACKUP_SUCCESS="${REQUIRE_MEDIA_BACKUP_SUCCESS:-true}"

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

notify_discord() {
    local status="$1"
    local message="$2"

    if [[ "$SUPPRESS_DISCORD" == "true" ]]; then
        log "Discord notification is suppressed"
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

    local host now updated major_updates latest_versions payload
    host=$(hostname)
    now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    updated=$(join_items ', ' "${UPDATED_CONTAINERS[@]}")
    major_updates=$(join_items '; ' "${MAJOR_UPDATE_MESSAGES[@]}")
    latest_versions=$(join_items '; ' "${LATEST_VERSION_SUMMARY[@]}")
    [[ -n "$updated" ]] || updated="none"
    [[ -n "$major_updates" ]] || major_updates="none"
    [[ -n "$latest_versions" ]] || latest_versions="unknown"

    payload=$(jq -n \
        --arg status "$status" \
        --arg host "$host" \
        --arg now "$now" \
        --arg message "$message" \
        --arg updated "$updated" \
        --arg major_updates "$major_updates" \
        --arg latest_versions "$latest_versions" \
        --arg dry_run "$DRY_RUN" \
        --arg check_only "$CHECK_ONLY" \
        --arg log_file "$LOG_FILE" \
        '{content: ("**media app update " + $status + "**\n"
            + "host: `" + $host + "`\n"
            + "time: `" + $now + "`\n"
            + "message: " + $message + "\n"
            + "latest: `" + $latest_versions + "`\n"
            + "major updates: `" + $major_updates + "`\n"
            + "updated containers: `" + $updated + "`\n"
            + "dry-run: `" + $dry_run + "`\n"
            + "check-only: `" + $check_only + "`\n"
            + "log: `" + $log_file + "`")}')

    if ! curl -fsS -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null; then
        log "WARNING: Discord notification failed"
    fi
}

write_summary() {
    [[ -n "$SUMMARY_FILE" ]] || return 0

    local status="$1"
    local message="$2"
    local updated major_updates latest_versions
    updated=$(join_items ', ' "${UPDATED_CONTAINERS[@]}")
    major_updates=$(join_items '; ' "${MAJOR_UPDATE_MESSAGES[@]}")
    latest_versions=$(join_items '; ' "${LATEST_VERSION_SUMMARY[@]}")
    [[ -n "$updated" ]] || updated="none"
    [[ -n "$major_updates" ]] || major_updates="none"
    [[ -n "$latest_versions" ]] || latest_versions="unknown"

    {
        printf 'MEDIA_APP_UPDATE_STATUS=%q\n' "$status"
        printf 'MEDIA_APP_UPDATE_MESSAGE=%q\n' "$message"
        printf 'MEDIA_APP_UPDATED_CONTAINERS=%q\n' "$updated"
        printf 'MEDIA_APP_MAJOR_UPDATES=%q\n' "$major_updates"
        printf 'MEDIA_APP_LATEST_VERSIONS=%q\n' "$latest_versions"
        printf 'MEDIA_APP_DRY_RUN=%q\n' "$DRY_RUN"
        printf 'MEDIA_APP_CHECK_ONLY=%q\n' "$CHECK_ONLY"
        printf 'MEDIA_APP_LOG_FILE=%q\n' "$LOG_FILE"
    } > "$SUMMARY_FILE"
}

on_exit() {
    local exit_code=$?
    local status message
    trap - EXIT

    if [[ -n "$BEFORE_FILE" ]]; then
        rm -f "$BEFORE_FILE"
    fi

    if [[ $exit_code -eq 0 ]]; then
        if (( ${#MAJOR_UPDATE_MESSAGES[@]} > 0 )); then
            status="major-update-detected"
        elif (( ${#UPDATED_CONTAINERS[@]} > 0 )); then
            status="updated"
        else
            status="succeeded"
        fi

        if [[ "$CHECK_ONLY" == "true" ]]; then
            message="version check completed"
        elif [[ "$DRY_RUN" == "true" ]]; then
            message="dry run completed"
        else
            message="app update completed"
        fi
        write_summary "$status" "$message"
        notify_discord "$status" "$message"
    else
        write_summary "failed" "failed at step: ${CURRENT_STEP}"
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

github_latest_tag() {
    local repo="$1"
    curl -fsSL \
        --retry 3 \
        --connect-timeout 10 \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ManageMediaServer-media-app-update" \
        "https://api.github.com/repos/${repo}/releases/latest" \
        | jq -r '.tag_name'
}

major_from_tag() {
    local tag="$1"
    tag="${tag#v}"
    if [[ ! "$tag" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
        log "ERROR: cannot parse semantic version tag: $tag"
        exit 1
    fi
    printf '%s' "${tag%%.*}"
}

check_latest_major() {
    local label="$1"
    local repo="$2"
    local allowed_major="$3"
    local latest_tag latest_major

    CURRENT_STEP="check latest ${label} release"
    latest_tag=$(github_latest_tag "$repo")
    latest_major=$(major_from_tag "$latest_tag")
    LATEST_VERSION_SUMMARY+=("${label}=${latest_tag}")

    log "${label} latest release: tag=${latest_tag} major=${latest_major} allowed_major=${allowed_major}"

    if (( latest_major > allowed_major )); then
        MAJOR_UPDATE_MESSAGES+=("${label} ${latest_tag} is newer than allowed major ${allowed_major}")
        log "WARNING: ${label} major update detected: ${latest_tag}"
    elif (( latest_major < allowed_major )); then
        log "WARNING: ${label} latest major ${latest_major} is older than configured allowed major ${allowed_major}"
    fi
}

compose_config() {
    local compose_dir="$1"
    (cd "$compose_dir" && docker compose -f docker-compose.yml config)
}

validate_immich_pin() {
    local images image found_server=false found_ml=false

    CURRENT_STEP="validate Immich major pin"
    images=$(compose_config "$IMMICH_COMPOSE_DIR" | awk '/image: ghcr.io\/immich-app\/immich-server:/ || /image: ghcr.io\/immich-app\/immich-machine-learning:/ {print $2}')

    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        case "$image" in
            ghcr.io/immich-app/immich-server:v${IMMICH_ALLOWED_MAJOR}|ghcr.io/immich-app/immich-server:v${IMMICH_ALLOWED_MAJOR}-*)
                found_server=true
                ;;
            ghcr.io/immich-app/immich-machine-learning:v${IMMICH_ALLOWED_MAJOR}|ghcr.io/immich-app/immich-machine-learning:v${IMMICH_ALLOWED_MAJOR}-*)
                found_ml=true
                ;;
            *)
                log "ERROR: Immich image is not pinned to major v${IMMICH_ALLOWED_MAJOR}: ${image}"
                exit 1
                ;;
        esac
    done <<< "$images"

    [[ "$found_server" == "true" ]] || { log "ERROR: Immich server image was not found in compose config"; exit 1; }
    [[ "$found_ml" == "true" ]] || { log "ERROR: Immich machine-learning image was not found in compose config"; exit 1; }
    log "Immich images are pinned to major v${IMMICH_ALLOWED_MAJOR}"
}

validate_jellyfin_pin() {
    local image

    CURRENT_STEP="validate Jellyfin major pin"
    image=$(compose_config "$JELLYFIN_COMPOSE_DIR" | awk '/image: .*jellyfin\/jellyfin:/ {print $2; exit}')

    if [[ "$image" != "jellyfin/jellyfin:${JELLYFIN_ALLOWED_MAJOR}" ]]; then
        log "ERROR: Jellyfin image is not pinned to major ${JELLYFIN_ALLOWED_MAJOR}: ${image:-missing}"
        exit 1
    fi
    log "Jellyfin image is pinned to major ${JELLYFIN_ALLOWED_MAJOR}"
}

verify_backup_success() {
    if [[ "$SKIP_BACKUP_CHECK" == "true" || "$REQUIRE_MEDIA_BACKUP_SUCCESS" != "true" ]]; then
        log "Skipping media-backup.service result check"
        return 0
    fi

    CURRENT_STEP="check latest media backup result"
    command -v systemctl >/dev/null || { log "ERROR: systemctl is not available"; exit 1; }

    if systemctl is-active --quiet media-backup.service; then
        log "ERROR: media-backup.service is still running"
        exit 1
    fi

    local result status timestamp
    result=$(systemctl show media-backup.service -p Result --value 2>/dev/null || true)
    status=$(systemctl show media-backup.service -p ExecMainStatus --value 2>/dev/null || true)
    timestamp=$(systemctl show media-backup.service -p InactiveEnterTimestamp --value 2>/dev/null || true)

    if [[ "$result" != "success" || "${status:-1}" != "0" ]]; then
        log "ERROR: latest media-backup.service result is not successful: result=${result:-unknown} status=${status:-unknown}"
        exit 1
    fi

    log "Latest media-backup.service result OK: result=${result} status=${status} inactive_at=${timestamp:-unknown}"
}

assert_prerequisites() {
    CURRENT_STEP="preflight"
    command -v curl >/dev/null || { log "ERROR: curl is not installed"; exit 1; }
    command -v jq >/dev/null || { log "ERROR: jq is not installed"; exit 1; }
    command -v docker >/dev/null || { log "ERROR: docker is not installed"; exit 1; }
    command -v flock >/dev/null || { log "ERROR: flock is not installed"; exit 1; }

    [[ -d "$PROD_ROOT" ]] || { log "ERROR: PROD_ROOT is missing: ${PROD_ROOT}"; exit 1; }
    [[ -f "${IMMICH_COMPOSE_DIR}/docker-compose.yml" ]] || { log "ERROR: Immich compose file is missing: ${IMMICH_COMPOSE_DIR}/docker-compose.yml"; exit 1; }
    [[ -f "${JELLYFIN_COMPOSE_DIR}/docker-compose.yml" ]] || { log "ERROR: Jellyfin compose file is missing: ${JELLYFIN_COMPOSE_DIR}/docker-compose.yml"; exit 1; }

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log "Check-only mode; skipping mount, free-space, and media-backup.service result checks"
        validate_immich_pin
        validate_jellyfin_pin
        return 0
    fi

    if ! mountpoint -q "$BACKUP_ROOT"; then
        log "ERROR: backup root is not mounted: $BACKUP_ROOT"
        exit 1
    fi

    assert_min_free_kib "root filesystem" "/" "$ROOT_MIN_FREE_KIB"
    assert_min_free_kib "data root" "/mnt/data" "$DATA_MIN_FREE_KIB"
    assert_min_free_kib "backup root" "$BACKUP_ROOT" "$BACKUP_MIN_FREE_KIB"

    verify_backup_success
    validate_immich_pin
    validate_jellyfin_pin
}

capture_container_images() {
    local output_file="$1"
    shift
    local container image_id

    : > "$output_file"
    for container in "$@"; do
        image_id=$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || true)
        printf '%s %s\n' "$container" "$image_id" >> "$output_file"
    done
}

record_container_changes() {
    local before_file="$1"
    local container before_image after_image

    while read -r container before_image; do
        [[ -n "$container" ]] || continue
        after_image=$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || true)
        if [[ "$before_image" != "$after_image" ]]; then
            UPDATED_CONTAINERS+=("$container")
            log "Container image changed: ${container} before=${before_image:-missing} after=${after_image:-missing}"
        fi
    done < "$before_file"
}

run_compose_update() {
    local label="$1"
    local compose_dir="$2"

    CURRENT_STEP="update ${label}"
    log "${label} compose directory: ${compose_dir}"

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log "${label}: check-only mode; skipping docker compose pull/up"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "${label}: dry-run; would run: docker compose -f docker-compose.yml pull"
        log "${label}: dry-run; would run: docker compose -f docker-compose.yml up -d"
        return 0
    fi

    (cd "$compose_dir" && docker compose -f docker-compose.yml pull)
    (cd "$compose_dir" && docker compose -f docker-compose.yml up -d)
}

log_compose_ps() {
    local label="$1"
    local compose_dir="$2"

    log "${label} compose ps:"
    (cd "$compose_dir" && docker compose -f docker-compose.yml ps) 2>&1 | tee -a "$LOG_FILE"
}

wait_for_http() {
    local label="$1"
    local url="$2"
    local attempt

    CURRENT_STEP="health check ${label}"
    for (( attempt=1; attempt<=HEALTH_RETRIES; attempt++ )); do
        if curl -fsSIL --max-time 10 "$url" >/dev/null; then
            log "${label} HTTP health OK: ${url}"
            return 0
        fi
        log "${label} HTTP health not ready: attempt=${attempt}/${HEALTH_RETRIES} url=${url}"
        sleep "$HEALTH_RETRY_SLEEP_SECONDS"
    done

    log "ERROR: ${label} HTTP health failed: ${url}"
    exit 1
}

verify_health() {
    if [[ "$CHECK_ONLY" == "true" || "$DRY_RUN" == "true" ]]; then
        log "Skipping health checks in check-only/dry-run mode"
        return 0
    fi

    log_compose_ps "Immich" "$IMMICH_COMPOSE_DIR"
    log_compose_ps "Jellyfin" "$JELLYFIN_COMPOSE_DIR"
    wait_for_http "Immich" "$IMMICH_HEALTH_URL"
    wait_for_http "Jellyfin" "$JELLYFIN_HEALTH_URL"
}

main() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "ERROR: another media app update is already running"
        exit 1
    fi

    log "=== media app update start ==="
    log "PROD_ROOT=${PROD_ROOT}"
    log "DRY_RUN=${DRY_RUN}"
    log "CHECK_ONLY=${CHECK_ONLY}"

    assert_prerequisites

    check_latest_major "Immich" "immich-app/immich" "$IMMICH_ALLOWED_MAJOR"
    check_latest_major "Jellyfin" "jellyfin/jellyfin" "$JELLYFIN_ALLOWED_MAJOR"

    BEFORE_FILE=$(mktemp)

    capture_container_images "$BEFORE_FILE" \
        immich_server \
        immich_machine_learning \
        immich_redis \
        immich_postgres \
        jellyfin

    run_compose_update "Immich" "$IMMICH_COMPOSE_DIR"
    run_compose_update "Jellyfin" "$JELLYFIN_COMPOSE_DIR"

    if [[ "$CHECK_ONLY" != "true" && "$DRY_RUN" != "true" ]]; then
        record_container_changes "$BEFORE_FILE"
    fi

    verify_health

    log "=== media app update completed ==="
}

main
