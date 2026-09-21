#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
COMPOSE_FILE="${TOKEN_MONITOR_COMPOSE_FILE:-${REPO_ROOT}/token-monitor/compose.yaml}"
DEPLOY_ENV="${TOKEN_MONITOR_DEPLOY_ENV:-${REPO_ROOT}/config/env/token-monitor-deploy.env}"
COMMON_ENV="${TOKEN_MONITOR_COMMON_ENV:-${REPO_ROOT}/config/env/token-monitor-common.env}"
LOG_DIR="${TOKEN_MONITOR_LOG_DIR:-/mnt/data/token-monitor/update/logs}"
LOG_FILE="${TOKEN_MONITOR_LOG_FILE:-${LOG_DIR}/update.log}"
LOCK_FILE="${TOKEN_MONITOR_LOCK_FILE:-${LOG_DIR}/update.lock}"
SUMMARY_FILE="${SUMMARY_FILE:-}"
DRY_RUN=false
CHECK_ONLY=false
CANDIDATE_NAME="token-monitor-hub-candidate"
CANDIDATE_DATA=""

usage() {
    cat <<'USAGE'
Usage: update.sh [--dry-run] [--check-only]

Checks the latest stable Token Monitor release. A real update builds and tests
one shared image, checks a candidate hub, backs up both hub stores, and rolls
the work hub, private hub, and private agent forward in that order.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --check-only) CHECK_ONLY=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$LOG_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$1" | tee -a "$LOG_FILE"
}

write_summary() {
    [[ -n "$SUMMARY_FILE" ]] || return 0
    {
        printf 'TOKEN_MONITOR_UPDATE_STATUS=%q\n' "${UPDATE_STATUS:-unknown}"
        printf 'TOKEN_MONITOR_CURRENT_VERSION=%q\n' "${CURRENT_VERSION:-unknown}"
        printf 'TOKEN_MONITOR_LATEST_VERSION=%q\n' "${LATEST_VERSION:-unknown}"
        printf 'TOKEN_MONITOR_UPDATED_VERSION=%q\n' "${UPDATED_VERSION:-none}"
        printf 'TOKEN_MONITOR_UPDATE_LOG_FILE=%q\n' "$LOG_FILE"
    } > "$SUMMARY_FILE"
}

cleanup() {
    docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true
    if [[ -n "$CANDIDATE_DATA" && -d "$CANDIDATE_DATA" ]]; then
        rm -rf "$CANDIDATE_DATA"
    fi
    write_summary
}
trap cleanup EXIT

[[ -f "$DEPLOY_ENV" ]] || { log "ERROR: missing $DEPLOY_ENV"; UPDATE_STATUS=failed; exit 1; }
[[ -f "$COMMON_ENV" ]] || { log "ERROR: missing $COMMON_ENV"; UPDATE_STATUS=failed; exit 1; }

set -a
# shellcheck disable=SC1090
source "$DEPLOY_ENV"
# shellcheck disable=SC1090
source "$COMMON_ENV"
set +a

CURRENT_VERSION="${TOKEN_MONITOR_VERSION:-}"
[[ "$CURRENT_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { log "ERROR: invalid TOKEN_MONITOR_VERSION in $DEPLOY_ENV"; UPDATE_STATUS=failed; exit 1; }

exec 9>"$LOCK_FILE"
flock -n 9 || { log "ERROR: another Token Monitor update is running"; UPDATE_STATUS=failed; exit 1; }

LATEST_VERSION=$(curl -fsSL --max-time 30 \
    https://api.github.com/repos/Javis603/token-monitor/releases/latest \
    | jq -r 'select(.draft == false and .prerelease == false) | .tag_name')

[[ "$LATEST_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { log "ERROR: GitHub returned an invalid release tag"; UPDATE_STATUS=failed; exit 1; }

log "current=${CURRENT_VERSION} latest=${LATEST_VERSION}"

if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    UPDATE_STATUS=succeeded
    UPDATED_VERSION=none
    log "Token Monitor is already current"
    exit 0
fi

if [[ "$CHECK_ONLY" == "true" || "$DRY_RUN" == "true" ]]; then
    UPDATE_STATUS=update_available
    UPDATED_VERSION=none
    log "update available; no changes made"
    exit 0
fi

"${SCRIPT_DIR}/backup-data.sh"
"${SCRIPT_DIR}/build-image.sh" "$LATEST_VERSION"

CANDIDATE_DATA=$(mktemp -d "${TMPDIR:-/tmp}/token-monitor-candidate.XXXXXX")
chmod 0777 "$CANDIDATE_DATA"
docker run -d --rm \
    --name "$CANDIDATE_NAME" \
    --env-file "$COMMON_ENV" \
    -e TOKEN_MONITOR_HOST=0.0.0.0 \
    -e TOKEN_MONITOR_PORT=18321 \
    -e TOKEN_MONITOR_DATA_FILE=/var/lib/token-monitor/devices.json \
    -p 127.0.0.1:18321:18321 \
    -v "${CANDIDATE_DATA}:/var/lib/token-monitor" \
    "manage-media/token-monitor:${LATEST_VERSION}" >/dev/null

candidate_ok=false
for _ in {1..30}; do
    if curl -fsS --max-time 2 http://127.0.0.1:18321/api/health \
        | jq -e '.ok == true and .role == "hub"' >/dev/null 2>&1; then
        candidate_ok=true
        break
    fi
    sleep 1
done
[[ "$candidate_ok" == "true" ]] \
    || { log "ERROR: candidate hub failed its health check"; UPDATE_STATUS=failed; exit 1; }

DEPLOY_BACKUP=$(mktemp "${DEPLOY_ENV}.backup.XXXXXX")
cp -a "$DEPLOY_ENV" "$DEPLOY_BACKUP"
deploy_tmp=$(mktemp "${DEPLOY_ENV}.new.XXXXXX")
awk -v version="$LATEST_VERSION" '
    BEGIN { replaced = 0 }
    /^TOKEN_MONITOR_VERSION=/ { print "TOKEN_MONITOR_VERSION=" version; replaced = 1; next }
    { print }
    END { if (!replaced) print "TOKEN_MONITOR_VERSION=" version }
' "$DEPLOY_ENV" > "$deploy_tmp"
chmod --reference="$DEPLOY_ENV" "$deploy_tmp"
mv "$deploy_tmp" "$DEPLOY_ENV"

export TOKEN_MONITOR_VERSION="$LATEST_VERSION"
compose=(docker compose --env-file "$DEPLOY_ENV" -f "$COMPOSE_FILE")
rollback() {
    log "rolling back to ${CURRENT_VERSION}"
    cp -a "$DEPLOY_BACKUP" "$DEPLOY_ENV"
    export TOKEN_MONITOR_VERSION="$CURRENT_VERSION"
    "${compose[@]}" up -d --no-build --wait --wait-timeout 90 hub-work hub-private agent-private || true
}

if ! "${compose[@]}" up -d --no-build --wait --wait-timeout 90 hub-work \
    || ! "${SCRIPT_DIR}/healthcheck.sh" \
    || ! "${compose[@]}" up -d --no-build --wait --wait-timeout 90 hub-private \
    || ! "${SCRIPT_DIR}/healthcheck.sh" \
    || ! "${compose[@]}" up -d --no-build agent-private; then
    rollback
    UPDATE_STATUS=failed
    exit 1
fi

rm -f "$DEPLOY_BACKUP"
UPDATED_VERSION="$LATEST_VERSION"
UPDATE_STATUS=updated
log "Token Monitor updated to ${LATEST_VERSION}"
