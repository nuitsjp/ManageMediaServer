#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"

sudo install -m 0755 -D "${REPO_ROOT}/scripts/ops/media-backup.sh" "${PROD_ROOT}/scripts/ops/media-backup.sh"
sudo install -m 0644 -D "${REPO_ROOT}/config/env/media-backup.env.example" "${PROD_ROOT}/config/env/media-backup.env.example"

if [[ ! -f "${PROD_ROOT}/config/env/media-backup.env" ]]; then
    sudo install -m 0640 -o mediaserver -g mediaserver \
        "${REPO_ROOT}/config/env/media-backup.env.example" \
        "${PROD_ROOT}/config/env/media-backup.env"
fi

sudo install -m 0644 "${REPO_ROOT}/systemd/media-backup.service" /etc/systemd/system/media-backup.service
sudo install -m 0644 "${REPO_ROOT}/systemd/media-backup.timer" /etc/systemd/system/media-backup.timer

sudo systemctl daemon-reload
sudo systemctl enable --now media-backup.timer
sudo systemctl list-timers media-backup.timer --no-pager
