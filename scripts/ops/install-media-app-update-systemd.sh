#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"

sudo install -m 0755 -D "${REPO_ROOT}/scripts/ops/media-app-update.sh" "${PROD_ROOT}/scripts/ops/media-app-update.sh"
sudo install -m 0644 -D "${REPO_ROOT}/config/env/media-app-update.env.example" "${PROD_ROOT}/config/env/media-app-update.env.example"

if [[ ! -f "${PROD_ROOT}/config/env/media-app-update.env" ]]; then
    sudo install -m 0640 -o mediaserver -g mediaserver \
        "${REPO_ROOT}/config/env/media-app-update.env.example" \
        "${PROD_ROOT}/config/env/media-app-update.env"
fi

sudo install -m 0644 "${REPO_ROOT}/systemd/media-app-update.service" /etc/systemd/system/media-app-update.service
sudo install -m 0644 "${REPO_ROOT}/systemd/media-app-update.timer" /etc/systemd/system/media-app-update.timer

sudo systemctl daemon-reload
sudo systemctl enable --now media-app-update.timer
sudo systemctl list-timers media-app-update.timer --no-pager
