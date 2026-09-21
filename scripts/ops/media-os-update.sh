#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

MEDIA_OS_UPDATE_ENV="${MEDIA_OS_UPDATE_ENV:-${REPO_ROOT}/config/env/media-os-update.env}"

DRY_RUN=false
CHECK_ONLY=false
CURRENT_STEP="initializing"
SUMMARY_FILE="${SUMMARY_FILE:-}"

usage() {
    cat <<'USAGE'
Usage: media-os-update.sh [--dry-run] [--check-only]

Updates OS packages at the end of the daily maintenance workflow.

Options:
  --dry-run     Show planned apt and snap updates without changing packages.
  --check-only  Check pending updates and reboot requirement only.
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

load_env_file "$MEDIA_OS_UPDATE_ENV"

LOG_DIR="${LOG_DIR:-/mnt/data/config/media-os-update/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/media-os-update.log}"
LOCK_FILE="${LOCK_FILE:-${LOG_DIR}/media-os-update.lock}"

ROOT_MIN_FREE_KIB="${ROOT_MIN_FREE_KIB:-1048576}"
DATA_MIN_FREE_KIB="${DATA_MIN_FREE_KIB:-1048576}"
BACKUP_MIN_FREE_KIB="${BACKUP_MIN_FREE_KIB:-1048576}"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backup}"

RUN_APT_UPDATE="${RUN_APT_UPDATE:-true}"
RUN_APT_UPGRADE="${RUN_APT_UPGRADE:-true}"
APT_UPGRADE_COMMAND="${APT_UPGRADE_COMMAND:-full-upgrade}"
RUN_APT_AUTOREMOVE="${RUN_APT_AUTOREMOVE:-false}"
RUN_SNAP_REFRESH="${RUN_SNAP_REFRESH:-true}"
APT_LOCK_TIMEOUT_SECONDS="${APT_LOCK_TIMEOUT_SECONDS:-600}"

APT_UPGRADED_PACKAGES="none"
APT_UPGRADED_COUNT=0
SNAP_REFRESHED_PACKAGES="none"
SNAP_REFRESHED_COUNT=0
AUTOREMOVE_STATUS="not_run"
REBOOT_REQUIRED="no"
REBOOT_REQUIRED_PACKAGES="none"

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

apt_args() {
    printf '%s\n' \
        "-o" "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT_SECONDS}" \
        "-o" "Dpkg::Options::=--force-confold"
}

run_apt_get() {
    local args=()
    mapfile -t args < <(apt_args)
    DEBIAN_FRONTEND=noninteractive apt-get "${args[@]}" "$@"
}

collect_apt_upgradable() {
    local packages=()
    mapfile -t packages < <(apt list --upgradable 2>/dev/null | awk -F/ 'NR > 1 {print $1}' | sort -u)
    APT_UPGRADED_COUNT="${#packages[@]}"
    if (( APT_UPGRADED_COUNT > 0 )); then
        APT_UPGRADED_PACKAGES=$(join_items ', ' "${packages[@]}")
    else
        APT_UPGRADED_PACKAGES="none"
    fi
    log "apt upgradable packages (${APT_UPGRADED_COUNT}): ${APT_UPGRADED_PACKAGES}"
}

collect_snap_refreshable() {
    local packages=()
    if ! command -v snap >/dev/null; then
        SNAP_REFRESHED_PACKAGES="snap command not installed"
        SNAP_REFRESHED_COUNT=0
        log "snap command is not installed"
        return 0
    fi

    mapfile -t packages < <(snap refresh --list 2>/dev/null | awk 'NR > 1 && $1 != "" {print $1}' | sort -u || true)
    SNAP_REFRESHED_COUNT="${#packages[@]}"
    if (( SNAP_REFRESHED_COUNT > 0 )); then
        SNAP_REFRESHED_PACKAGES=$(join_items ', ' "${packages[@]}")
    else
        SNAP_REFRESHED_PACKAGES="none"
    fi
    log "snap refreshable packages (${SNAP_REFRESHED_COUNT}): ${SNAP_REFRESHED_PACKAGES}"
}

check_reboot_required() {
    if [[ -f /var/run/reboot-required ]]; then
        REBOOT_REQUIRED="yes"
        if [[ -s /var/run/reboot-required.pkgs ]]; then
            mapfile -t packages < /var/run/reboot-required.pkgs
            REBOOT_REQUIRED_PACKAGES=$(join_items ', ' "${packages[@]}")
        else
            REBOOT_REQUIRED_PACKAGES="unknown"
        fi
    else
        REBOOT_REQUIRED="no"
        REBOOT_REQUIRED_PACKAGES="none"
    fi
    log "reboot required: ${REBOOT_REQUIRED}; packages: ${REBOOT_REQUIRED_PACKAGES}"
}

write_summary() {
    [[ -n "$SUMMARY_FILE" ]] || return 0

    local status="$1"
    local message="$2"
    {
        printf 'MEDIA_OS_UPDATE_STATUS=%q\n' "$status"
        printf 'MEDIA_OS_UPDATE_MESSAGE=%q\n' "$message"
        printf 'MEDIA_OS_APT_UPGRADED_PACKAGES=%q\n' "$APT_UPGRADED_PACKAGES"
        printf 'MEDIA_OS_APT_UPGRADED_COUNT=%q\n' "$APT_UPGRADED_COUNT"
        printf 'MEDIA_OS_SNAP_REFRESHED_PACKAGES=%q\n' "$SNAP_REFRESHED_PACKAGES"
        printf 'MEDIA_OS_SNAP_REFRESHED_COUNT=%q\n' "$SNAP_REFRESHED_COUNT"
        printf 'MEDIA_OS_AUTOREMOVE_STATUS=%q\n' "$AUTOREMOVE_STATUS"
        printf 'MEDIA_OS_REBOOT_REQUIRED=%q\n' "$REBOOT_REQUIRED"
        printf 'MEDIA_OS_REBOOT_REQUIRED_PACKAGES=%q\n' "$REBOOT_REQUIRED_PACKAGES"
        printf 'MEDIA_OS_DRY_RUN=%q\n' "$DRY_RUN"
        printf 'MEDIA_OS_CHECK_ONLY=%q\n' "$CHECK_ONLY"
        printf 'MEDIA_OS_LOG_FILE=%q\n' "$LOG_FILE"
    } > "$SUMMARY_FILE"
}

on_exit() {
    local exit_code=$?
    trap - EXIT
    if [[ $exit_code -eq 0 ]]; then
        write_summary "succeeded" "os update completed"
    else
        check_reboot_required || true
        write_summary "failed" "failed at step: ${CURRENT_STEP}"
    fi
    exit "$exit_code"
}

trap on_exit EXIT

assert_prerequisites() {
    CURRENT_STEP="preflight"
    command -v apt-get >/dev/null || { log "ERROR: apt-get is not installed"; exit 1; }
    command -v apt >/dev/null || { log "ERROR: apt is not installed"; exit 1; }

    if [[ "$CHECK_ONLY" != "true" && "$DRY_RUN" != "true" && "${EUID}" -ne 0 ]]; then
        log "ERROR: real OS updates require root"
        exit 1
    fi

    assert_min_free_kib "root filesystem" "/" "$ROOT_MIN_FREE_KIB"
    if [[ -d /mnt/data ]]; then
        assert_min_free_kib "data root" "/mnt/data" "$DATA_MIN_FREE_KIB"
    fi
    if mountpoint -q "$BACKUP_ROOT"; then
        assert_min_free_kib "backup root" "$BACKUP_ROOT" "$BACKUP_MIN_FREE_KIB"
    else
        log "backup root is not mounted; skipping backup free-space check for OS update"
    fi
}

run_apt_update() {
    [[ "$RUN_APT_UPDATE" == "true" ]] || return 0
    CURRENT_STEP="apt update"
    if [[ "$CHECK_ONLY" == "true" ]]; then
        log "check-only mode; skipping apt-get update"
        return 0
    fi
    log "apt-get update start"
    run_apt_get update 2>&1 | tee -a "$LOG_FILE"
    log "apt-get update done"
}

run_apt_upgrade() {
    [[ "$RUN_APT_UPGRADE" == "true" ]] || return 0
    CURRENT_STEP="apt ${APT_UPGRADE_COMMAND}"
    collect_apt_upgradable
    if [[ "$CHECK_ONLY" == "true" ]]; then
        log "check-only mode; skipping apt-get ${APT_UPGRADE_COMMAND}"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log "dry-run; would run apt-get -y ${APT_UPGRADE_COMMAND}"
        run_apt_get -s -y "$APT_UPGRADE_COMMAND" 2>&1 | tee -a "$LOG_FILE"
        return 0
    fi
    log "apt-get ${APT_UPGRADE_COMMAND} start"
    run_apt_get -y "$APT_UPGRADE_COMMAND" 2>&1 | tee -a "$LOG_FILE"
    log "apt-get ${APT_UPGRADE_COMMAND} done"
}

run_apt_autoremove() {
    if [[ "$RUN_APT_AUTOREMOVE" != "true" ]]; then
        AUTOREMOVE_STATUS="disabled"
        log "apt-get autoremove is disabled"
        return 0
    fi
    CURRENT_STEP="apt autoremove"
    if [[ "$CHECK_ONLY" == "true" ]]; then
        AUTOREMOVE_STATUS="skipped_check_only"
        log "check-only mode; skipping apt-get autoremove"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        AUTOREMOVE_STATUS="dry_run"
        log "dry-run; would run apt-get -y autoremove"
        run_apt_get -s -y autoremove 2>&1 | tee -a "$LOG_FILE"
        return 0
    fi
    log "apt-get autoremove start"
    run_apt_get -y autoremove 2>&1 | tee -a "$LOG_FILE"
    AUTOREMOVE_STATUS="succeeded"
    log "apt-get autoremove done"
}

run_snap_refresh() {
    [[ "$RUN_SNAP_REFRESH" == "true" ]] || return 0
    CURRENT_STEP="snap refresh"
    collect_snap_refreshable
    if ! command -v snap >/dev/null; then
        return 0
    fi
    if [[ "$CHECK_ONLY" == "true" ]]; then
        log "check-only mode; skipping snap refresh"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log "dry-run; would run snap refresh"
        return 0
    fi
    log "snap refresh start"
    snap refresh 2>&1 | tee -a "$LOG_FILE"
    log "snap refresh done"
}

main() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "ERROR: another OS update is already running"
        exit 1
    fi

    log "=== media OS update start ==="
    log "DRY_RUN=${DRY_RUN}"
    log "CHECK_ONLY=${CHECK_ONLY}"
    log "APT_UPGRADE_COMMAND=${APT_UPGRADE_COMMAND}"

    assert_prerequisites
    run_apt_update
    run_apt_upgrade
    run_apt_autoremove
    run_snap_refresh
    check_reboot_required

    log "=== media OS update completed ==="
}

main
