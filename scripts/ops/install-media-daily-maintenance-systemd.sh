#!/bin/bash

# Deploys every file the daily maintenance workflow needs, verifies that all
# enabled steps can start, and only then switches scheduling to
# media-daily-maintenance.timer. Also called by install-token-monitor.sh.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo --preserve-env=PROD_ROOT "$0" "$@"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"
BACKUP_DIR="${PROD_ROOT}/.deploy-backups/daily-maintenance-$(date '+%Y%m%d-%H%M%S')"

SCRIPTS=(
    scripts/ops/media-backup.sh
    scripts/ops/media-app-update.sh
    scripts/ops/rclone-media-sync.sh
    scripts/ops/media-os-update.sh
    scripts/ops/media-daily-maintenance.sh
)
ENV_EXAMPLES=(
    config/env/media-backup.env.example
    config/env/media-app-update.env.example
    config/env/media-os-update.env.example
    config/env/media-daily-maintenance.env.example
)
# Real env files created from their example only when missing.
DEFAULT_ENVS=(
    media-os-update.env
    media-daily-maintenance.env
)
UNITS=(
    media-daily-maintenance.service
    media-daily-maintenance.timer
)

for file in "${SCRIPTS[@]}" "${ENV_EXAMPLES[@]}"; do
    [[ -f "${REPO_ROOT}/${file}" ]] || { echo "ERROR: missing ${REPO_ROOT}/${file}" >&2; exit 1; }
done
for unit in "${UNITS[@]}"; do
    [[ -f "${REPO_ROOT}/systemd/${unit}" ]] || { echo "ERROR: missing ${REPO_ROOT}/systemd/${unit}" >&2; exit 1; }
done

install -d -m 0755 "$BACKUP_DIR"
for file in "${SCRIPTS[@]}"; do
    if [[ -f "${PROD_ROOT}/${file}" ]]; then
        install -D -m 0644 "${PROD_ROOT}/${file}" "${BACKUP_DIR}/${file}"
    fi
done
for unit in "${UNITS[@]}"; do
    if [[ -f "/etc/systemd/system/${unit}" ]]; then
        install -D -m 0644 "/etc/systemd/system/${unit}" "${BACKUP_DIR}/systemd/${unit}"
    fi
done
echo "Previous daily maintenance files were backed up under: ${BACKUP_DIR}"

for file in "${SCRIPTS[@]}"; do
    install -m 0755 -D "${REPO_ROOT}/${file}" "${PROD_ROOT}/${file}"
    echo "DEPLOY: ${PROD_ROOT}/${file}"
done
for file in "${ENV_EXAMPLES[@]}"; do
    install -m 0644 -D "${REPO_ROOT}/${file}" "${PROD_ROOT}/${file}"
done
for name in "${DEFAULT_ENVS[@]}"; do
    if [[ ! -f "${PROD_ROOT}/config/env/${name}" ]]; then
        install -m 0640 -o mediaserver -g mediaserver \
            "${REPO_ROOT}/config/env/${name}.example" \
            "${PROD_ROOT}/config/env/${name}"
        echo "CREATE: ${PROD_ROOT}/config/env/${name}"
    fi
done
for unit in "${UNITS[@]}"; do
    install -m 0644 "${REPO_ROOT}/systemd/${unit}" "/etc/systemd/system/${unit}"
done
systemctl daemon-reload

# Load the same environment the service uses so the preflight checks the
# production configuration.
if ! (
    set -a
    for env_file in media-daily-maintenance.env media-os-update.env notification.env; do
        # shellcheck disable=SC1090
        [[ -f "${PROD_ROOT}/config/env/${env_file}" ]] && source "${PROD_ROOT}/config/env/${env_file}"
    done
    set +a
    /usr/bin/bash "${PROD_ROOT}/scripts/ops/media-daily-maintenance.sh" --preflight
); then
    echo "ERROR: daily maintenance preflight failed; the timer was not enabled" >&2
    exit 1
fi

systemctl disable --now media-backup.timer media-app-update.timer rclone-media-sync.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
systemctl enable --now media-daily-maintenance.timer
systemctl list-timers media-daily-maintenance.timer media-backup.timer media-app-update.timer rclone-media-sync.timer apt-daily-upgrade.timer --no-pager
