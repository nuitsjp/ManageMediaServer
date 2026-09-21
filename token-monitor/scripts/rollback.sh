#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
DEPLOY_ENV="${TOKEN_MONITOR_DEPLOY_ENV:-${REPO_ROOT}/config/env/token-monitor-deploy.env}"
COMPOSE_FILE="${TOKEN_MONITOR_COMPOSE_FILE:-${REPO_ROOT}/token-monitor/compose.yaml}"
TARGET_VERSION="${1:-}"

[[ "$TARGET_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "Usage: rollback.sh vX.Y.Z" >&2; exit 2; }
docker image inspect "manage-media/token-monitor:${TARGET_VERSION}" >/dev/null

tmp=$(mktemp "${DEPLOY_ENV}.new.XXXXXX")
awk -v version="$TARGET_VERSION" '
    /^TOKEN_MONITOR_VERSION=/ { print "TOKEN_MONITOR_VERSION=" version; replaced = 1; next }
    { print }
    END { if (!replaced) print "TOKEN_MONITOR_VERSION=" version }
' "$DEPLOY_ENV" > "$tmp"
chmod --reference="$DEPLOY_ENV" "$tmp"
mv "$tmp" "$DEPLOY_ENV"

docker compose --env-file "$DEPLOY_ENV" -f "$COMPOSE_FILE" \
    up -d --no-build --wait --wait-timeout 90 hub-work hub-private agent-private
"${SCRIPT_DIR}/healthcheck.sh"
