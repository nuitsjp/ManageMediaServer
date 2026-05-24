#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"

sudo install -m 0755 -D "${REPO_ROOT}/scripts/ops/media-backup.sh" "${PROD_ROOT}/scripts/ops/media-backup.sh"
sudo install -m 0755 -D "${REPO_ROOT}/scripts/ops/media-app-update.sh" "${PROD_ROOT}/scripts/ops/media-app-update.sh"
sudo install -m 0755 -D "${REPO_ROOT}/scripts/ops/rclone-media-sync.sh" "${PROD_ROOT}/scripts/ops/rclone-media-sync.sh"
sudo install -m 0755 -D "${REPO_ROOT}/scripts/ops/media-os-update.sh" "${PROD_ROOT}/scripts/ops/media-os-update.sh"
sudo install -m 0755 -D "${REPO_ROOT}/scripts/ops/media-daily-maintenance.sh" "${PROD_ROOT}/scripts/ops/media-daily-maintenance.sh"

sudo install -m 0644 -D "${REPO_ROOT}/config/env/media-backup.env.example" "${PROD_ROOT}/config/env/media-backup.env.example"
sudo install -m 0644 -D "${REPO_ROOT}/config/env/media-app-update.env.example" "${PROD_ROOT}/config/env/media-app-update.env.example"
sudo install -m 0644 -D "${REPO_ROOT}/config/env/media-os-update.env.example" "${PROD_ROOT}/config/env/media-os-update.env.example"
sudo install -m 0644 -D "${REPO_ROOT}/config/env/media-daily-maintenance.env.example" "${PROD_ROOT}/config/env/media-daily-maintenance.env.example"

if [[ ! -f "${PROD_ROOT}/config/env/media-os-update.env" ]]; then
    sudo install -m 0640 -o mediaserver -g mediaserver \
        "${REPO_ROOT}/config/env/media-os-update.env.example" \
        "${PROD_ROOT}/config/env/media-os-update.env"
fi

if [[ ! -f "${PROD_ROOT}/config/env/media-daily-maintenance.env" ]]; then
    sudo install -m 0640 -o mediaserver -g mediaserver \
        "${REPO_ROOT}/config/env/media-daily-maintenance.env.example" \
        "${PROD_ROOT}/config/env/media-daily-maintenance.env"
fi

sudo install -m 0644 "${REPO_ROOT}/systemd/media-daily-maintenance.service" /etc/systemd/system/media-daily-maintenance.service
sudo install -m 0644 "${REPO_ROOT}/systemd/media-daily-maintenance.timer" /etc/systemd/system/media-daily-maintenance.timer

sudo systemctl daemon-reload
sudo systemctl disable --now media-backup.timer media-app-update.timer rclone-media-sync.timer apt-daily-upgrade.timer || true
sudo systemctl enable --now media-daily-maintenance.timer
sudo systemctl list-timers media-daily-maintenance.timer media-backup.timer media-app-update.timer rclone-media-sync.timer apt-daily-upgrade.timer --no-pager
