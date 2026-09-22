#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: sudo でこのスクリプトを実行してください" >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"
PROD_CONFIG_ROOT="${PROD_ROOT}/config/env"
BACKUP_ROOT="${MEDIA_HEALTH_BACKUP_ROOT:-/mnt/backup/media-health-check}"
BACKUP_DIR="${BACKUP_ROOT}/install-backups/$(date '+%Y%m%d-%H%M%S')"

required=(
    "${REPO_ROOT}/scripts/ops/media-health-check.sh"
    "${REPO_ROOT}/config/env/media-health-check.env.example"
    "${REPO_ROOT}/systemd/media-health-check.service"
    "${REPO_ROOT}/systemd/media-health-check.timer"
)
for file in "${required[@]}"; do
    [[ -f "$file" ]] || { echo "ERROR: missing $file" >&2; exit 1; }
done

[[ -d /mnt/backup ]] || { echo "ERROR: /mnt/backup is missing" >&2; exit 1; }
mountpoint -q /mnt/backup || { echo "ERROR: /mnt/backup is not a mountpoint" >&2; exit 1; }
install -d -m 0750 -o mediaserver -g mediaserver "$BACKUP_DIR"

backup_if_present() {
    local source="$1"
    local relative="$2"
    if [[ -f "$source" ]]; then
        install -d -m 0750 -o mediaserver -g mediaserver "${BACKUP_DIR}/$(dirname "$relative")"
        cp -a "$source" "${BACKUP_DIR}/${relative}"
    fi
}

backup_if_present "${PROD_ROOT}/scripts/ops/media-health-check.sh" "scripts/ops/media-health-check.sh"
backup_if_present "${PROD_CONFIG_ROOT}/media-health-check.env" "config/env/media-health-check.env"
backup_if_present /etc/systemd/system/media-health-check.service "systemd/media-health-check.service"
backup_if_present /etc/systemd/system/media-health-check.timer "systemd/media-health-check.timer"

install -m 0755 -D "${REPO_ROOT}/scripts/ops/media-health-check.sh" \
    "${PROD_ROOT}/scripts/ops/media-health-check.sh"
install -m 0644 -D "${REPO_ROOT}/config/env/media-health-check.env.example" \
    "${PROD_CONFIG_ROOT}/media-health-check.env.example"

if [[ ! -f "${PROD_CONFIG_ROOT}/media-health-check.env" ]]; then
    install -m 0640 -o mediaserver -g mediaserver \
        "${REPO_ROOT}/config/env/media-health-check.env.example" \
        "${PROD_CONFIG_ROOT}/media-health-check.env"
fi

install -m 0644 "${REPO_ROOT}/systemd/media-health-check.service" \
    /etc/systemd/system/media-health-check.service
install -m 0644 "${REPO_ROOT}/systemd/media-health-check.timer" \
    /etc/systemd/system/media-health-check.timer

systemctl daemon-reload
systemctl enable media-health-check.timer
systemctl restart media-health-check.timer

runuser -u mediaserver -- \
    /usr/bin/bash "${PROD_ROOT}/scripts/ops/media-health-check.sh" --no-notify
systemctl start media-health-check.service

systemctl --no-pager --full status media-health-check.timer || true
systemctl show media-health-check.service \
    --property=Result \
    --property=ExecMainStatus \
    --property=ExecMainStartTimestamp \
    --property=ExecMainExitTimestamp \
    --no-pager
systemctl list-timers media-health-check.timer --no-pager
echo "Previous health-check files were backed up under: $BACKUP_DIR"
