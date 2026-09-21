#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOKEN_MONITOR_VERSION="${1:-${TOKEN_MONITOR_VERSION:-}}"

if [[ ! "$TOKEN_MONITOR_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: expected a release tag such as v0.60.0" >&2
    exit 2
fi

docker build \
    --build-arg "TOKEN_MONITOR_VERSION=${TOKEN_MONITOR_VERSION}" \
    --tag "manage-media/token-monitor:${TOKEN_MONITOR_VERSION}" \
    --file "${SCRIPT_DIR}/../Dockerfile" \
    "${SCRIPT_DIR}/.."

docker run --rm "manage-media/token-monitor:${TOKEN_MONITOR_VERSION}" \
    node --test \
        tests/hub/server.test.js \
        tests/agent/runtime.test.js \
        tests/shared/syncPayload.test.js \
        tests/shared/hubProtocol.test.js \
        tests/shared/usage.test.js \
        tests/shared/sessionUsageArchive.test.js \
        tests/shared/sessionUsageArchiveStore.test.js \
        tests/shared/dailyHistoryArchive.test.js
