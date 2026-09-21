#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: sudo でこのスクリプトを実行してください" >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"
SOURCE_COMMON_ENV="${REPO_ROOT}/config/env/token-monitor-common.env"
PROD_CONFIG_ROOT="${PROD_ROOT}/config/env"
PROD_TOKEN_ROOT="${PROD_ROOT}/token-monitor"
BACKUP_ROOT="${TOKEN_MONITOR_BACKUP_ROOT:-/mnt/backup/token-monitor}"
BACKUP_DIR="${BACKUP_ROOT}/install-backups/$(date '+%Y%m%d-%H%M%S')"

required=(
    "${REPO_ROOT}/token-monitor/Dockerfile"
    "${REPO_ROOT}/token-monitor/compose.yaml"
    "${REPO_ROOT}/token-monitor/scripts/update.sh"
    "${REPO_ROOT}/token-monitor/systemd/token-monitor.service"
    "${REPO_ROOT}/scripts/ops/media-daily-maintenance.sh"
    "$SOURCE_COMMON_ENV"
)
for file in "${required[@]}"; do
    [[ -f "$file" ]] || { echo "ERROR: missing $file" >&2; exit 1; }
done

[[ -d /mnt/backup ]] || { echo "ERROR: /mnt/backup is missing" >&2; exit 1; }
mountpoint -q /mnt/backup || { echo "ERROR: /mnt/backup is not a mountpoint" >&2; exit 1; }
install -d -m 0750 -o mediaserver -g mediaserver "$BACKUP_DIR"

if [[ -d "$PROD_TOKEN_ROOT" ]]; then
    cp -a "$PROD_TOKEN_ROOT" "$BACKUP_DIR/token-monitor"
fi
if [[ -f "${PROD_ROOT}/scripts/ops/media-daily-maintenance.sh" ]]; then
    install -d -m 0750 -o mediaserver -g mediaserver "$BACKUP_DIR/scripts/ops"
    cp -a "${PROD_ROOT}/scripts/ops/media-daily-maintenance.sh" "$BACKUP_DIR/scripts/ops/"
fi
for file in token-monitor-common.env token-monitor-private.env token-monitor-work.env \
    token-monitor-agent-private.env token-monitor-deploy.env; do
    if [[ -f "${PROD_CONFIG_ROOT}/${file}" ]]; then
        cp -a "${PROD_CONFIG_ROOT}/${file}" "$BACKUP_DIR/"
    fi
done

install -d -m 0755 -o root -g root "$PROD_TOKEN_ROOT"
cp -a "${REPO_ROOT}/token-monitor/." "$PROD_TOKEN_ROOT/"
chown -R root:root "$PROD_TOKEN_ROOT"
find "$PROD_TOKEN_ROOT/scripts" -type f -name '*.sh' -exec chmod 0755 {} +
install -m 0755 -D "${REPO_ROOT}/scripts/ops/media-daily-maintenance.sh" \
    "${PROD_ROOT}/scripts/ops/media-daily-maintenance.sh"
install -m 0644 -D "${REPO_ROOT}/config/env/media-daily-maintenance.env.example" \
    "${PROD_ROOT}/config/env/media-daily-maintenance.env.example"

install -d -m 0750 -o mediaserver -g mediaserver "$PROD_CONFIG_ROOT"
install -m 0640 -o mediaserver -g mediaserver "$SOURCE_COMMON_ENV" \
    "${PROD_CONFIG_ROOT}/token-monitor-common.env"

install_env_if_missing() {
    local name="$1"
    local example="${REPO_ROOT}/config/env/${name}.example"
    local target="${PROD_CONFIG_ROOT}/${name}"
    [[ -f "$target" ]] || install -m 0640 -o mediaserver -g mediaserver "$example" "$target"
}

install_env_if_missing token-monitor-private.env
install_env_if_missing token-monitor-work.env
install_env_if_missing token-monitor-agent-private.env
install_env_if_missing token-monitor-deploy.env

install -d -m 0750 -o mediaserver -g mediaserver \
    /mnt/data/token-monitor/private/data \
    /mnt/data/token-monitor/work/data \
    /mnt/data/token-monitor/update/logs \
    /mnt/backup/token-monitor
install -d -m 0770 -o ubuntu -g mediaserver /mnt/data/token-monitor/agent-private/state

install -m 0644 "${REPO_ROOT}/token-monitor/systemd/token-monitor.service" \
    /etc/systemd/system/token-monitor.service
install -m 0644 "${REPO_ROOT}/token-monitor/systemd/token-monitor-update.service" \
    /etc/systemd/system/token-monitor-update.service
install -m 0644 "${REPO_ROOT}/token-monitor/systemd/token-monitor-update.timer" \
    /etc/systemd/system/token-monitor-update.timer

systemctl daemon-reload
systemctl disable --now token-monitor-update.timer >/dev/null 2>&1 || true

set -a
# shellcheck disable=SC1090
source "${PROD_CONFIG_ROOT}/token-monitor-deploy.env"
set +a

docker compose --env-file "${PROD_CONFIG_ROOT}/token-monitor-deploy.env" \
    -f "${PROD_TOKEN_ROOT}/compose.yaml" build
systemctl enable token-monitor.service
systemctl restart token-monitor.service

tailscale serve --yes --bg --https=17321 http://127.0.0.1:17321
tailscale serve --yes --bg --https=17322 http://127.0.0.1:17322

"${PROD_TOKEN_ROOT}/scripts/healthcheck.sh"
systemctl --no-pager --full status token-monitor.service
docker compose --env-file "${PROD_CONFIG_ROOT}/token-monitor-deploy.env" \
    -f "${PROD_TOKEN_ROOT}/compose.yaml" ps
tailscale serve status

echo "Previous production files, when present, were backed up under: $BACKUP_DIR"
echo "Token Monitor private/work hubs and private agent were installed."
