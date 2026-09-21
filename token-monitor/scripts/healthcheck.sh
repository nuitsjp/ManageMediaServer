#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
CONFIG_ROOT="${TOKEN_MONITOR_CONFIG_ROOT:-${REPO_ROOT}/config/env}"
COMMON_ENV="${TOKEN_MONITOR_COMMON_ENV:-${CONFIG_ROOT}/token-monitor-common.env}"

[[ -f "$COMMON_ENV" ]] || { echo "ERROR: missing $COMMON_ENV" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$COMMON_ENV"
set +a

check_health() {
    local name="$1"
    local port="$2"
    local response
    response=$(curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/health")
    jq -e --arg role hub '.ok == true and .role == $role' <<<"$response" >/dev/null
    printf 'OK: %s hub is healthy on localhost:%s\n' "$name" "$port"
}

check_health private 17321
check_health work 17322

if [[ "${1:-}" == "--require-agent" ]]; then
    devices=$(curl -fsS --max-time 10 \
        -H "Authorization: Bearer ${TOKEN_MONITOR_SECRET}" \
        http://127.0.0.1:17321/api/devices)
    jq -e --arg id "${TOKEN_MONITOR_DEVICE_ID:-home-ubuntu}" \
        '.devices | any(.deviceId == $id)' <<<"$devices" >/dev/null
    printf 'OK: private agent device is present\n'
fi
