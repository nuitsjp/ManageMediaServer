#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"

if [[ ! -x "${PROD_ROOT}/scripts/ops/media-health-check.sh" ]]; then
    echo "Missing deployed script: ${PROD_ROOT}/scripts/ops/media-health-check.sh" >&2
    echo "Run scripts/ops/deploy-managed-files.sh first." >&2
    exit 1
fi

sudo install -m 0644 "${REPO_ROOT}/systemd/media-health-check.service" /etc/systemd/system/media-health-check.service
sudo install -m 0644 "${REPO_ROOT}/systemd/media-health-check.timer" /etc/systemd/system/media-health-check.timer
sudo systemctl daemon-reload
sudo systemctl enable --now media-health-check.timer
sudo systemctl list-timers media-health-check.timer --no-pager
