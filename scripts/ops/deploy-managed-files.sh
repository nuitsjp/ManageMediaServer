#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PROD_ROOT="${PROD_ROOT:-/home/mediaserver/ManageMediaServer}"
SYSTEMD_ROOT="${SYSTEMD_ROOT:-/etc/systemd/system}"
BACKUP_PARENT="${BACKUP_PARENT:-${PROD_ROOT}/.deploy-backups}"
DRY_RUN=false
SMARTHOME_ONLY=false
MQTT_ONLY=false

usage() {
    cat <<USAGE
Usage: $0 [--dry-run] [--smarthome-only|--mqtt-only]

Deploy only Git-managed operational files from:
  ${REPO_ROOT}

to the production copy:
  ${PROD_ROOT}

and systemd units to:
  ${SYSTEMD_ROOT}

Host-specific files such as .env, config/env/*.env, rclone.conf, logs,
/mnt/data, and /mnt/backup are not copied or overwritten.

Options:
  --dry-run  Show planned changes without writing files
  --smarthome-only  Deploy only smart home foundation files (no other services)
  --mqtt-only  Deploy only smart home MQTT files
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            ;;
        --smarthome-only)
            SMARTHOME_ONLY=true
            ;;
        --mqtt-only)
            MQTT_ONLY=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="${BACKUP_PARENT}/${TIMESTAMP}"
COPIED=0
UNCHANGED=0
BACKED_UP=0

sudo_run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run]'
        if [[ ${#SUDO[@]} -gt 0 ]]; then
            printf ' %q' "${SUDO[@]}"
        fi
        printf ' %q' "$@"
        printf '\n'
    else
        "${SUDO[@]}" "$@"
    fi
}

sudo_check() {
    if [[ "$DRY_RUN" == true ]]; then
        "$@"
    else
        "${SUDO[@]}" "$@"
    fi
}

require_source() {
    local source=$1
    if [[ ! -e "${REPO_ROOT}/${source}" ]]; then
        echo "Required source is missing: ${REPO_ROOT}/${source}" >&2
        exit 1
    fi
}

backup_destination() {
    local destination=$1
    local backup_path="${BACKUP_DIR}${destination}"

    if sudo_check test -e "$destination"; then
        sudo_run install -d -m 0755 "$(dirname "$backup_path")"
        sudo_run cp -a "$destination" "$backup_path"
        BACKED_UP=$((BACKED_UP + 1))
    fi
}

install_managed_file() {
    local source=$1
    local destination=$2
    local mode=$3
    local source_path="${REPO_ROOT}/${source}"

    require_source "$source"

    if sudo_check test -e "$destination" && sudo_check cmp -s "$source_path" "$destination"; then
        echo "unchanged: $destination"
        UNCHANGED=$((UNCHANGED + 1))
        return
    fi

    backup_destination "$destination"
    sudo_run install -m "$mode" -D "$source_path" "$destination"
    echo "deployed:  $destination"
    COPIED=$((COPIED + 1))
}

check_host_file() {
    local path=$1
    if sudo_check test -e "$path"; then
        echo "host file exists:   $path"
    else
        echo "host file missing:  $path"
    fi
}

if [[ ! -d "$REPO_ROOT/.git" ]]; then
    echo "This script must be run from a Git checkout layout." >&2
    exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run: no files will be changed."
fi

echo "Deploying managed files"
echo "source:      $REPO_ROOT"
echo "production:  $PROD_ROOT"
echo "systemd:     $SYSTEMD_ROOT"
echo "backup dir:  $BACKUP_DIR"

managed_files=(
    "README.md|${PROD_ROOT}/README.md|0644"
    "AGENTS.md|${PROD_ROOT}/AGENTS.md|0644"
    "LICENSE|${PROD_ROOT}/LICENSE|0644"
    "docs/同期設計.md|${PROD_ROOT}/docs/同期設計.md|0644"
    "docker/immich/docker-compose.yml|${PROD_ROOT}/docker/immich/docker-compose.yml|0644"
    "docker/immich/.env.example|${PROD_ROOT}/docker/immich/.env.example|0644"
    "docker/jellyfin/docker-compose.yml|${PROD_ROOT}/docker/jellyfin/docker-compose.yml|0644"
    "config/env/media-firewall.env.example|${PROD_ROOT}/config/env/media-firewall.env.example|0644"
    "config/env/media-backup.env.example|${PROD_ROOT}/config/env/media-backup.env.example|0644"
    "config/env/media-app-update.env.example|${PROD_ROOT}/config/env/media-app-update.env.example|0644"
    "config/env/media-health-check.env.example|${PROD_ROOT}/config/env/media-health-check.env.example|0644"
    "config/env/notification.env.example|${PROD_ROOT}/config/env/notification.env.example|0644"
    "config/rclone/rclone.conf.example|${PROD_ROOT}/config/rclone/rclone.conf.example|0644"
    "config/rclone/media-sync-excludes.txt|${PROD_ROOT}/config/rclone/media-sync-excludes.txt|0644"
    "scripts/ops/apply-media-firewall.sh|${PROD_ROOT}/scripts/ops/apply-media-firewall.sh|0755"
    "scripts/ops/deploy-managed-files.sh|${PROD_ROOT}/scripts/ops/deploy-managed-files.sh|0755"
    "scripts/ops/install-media-app-update-systemd.sh|${PROD_ROOT}/scripts/ops/install-media-app-update-systemd.sh|0755"
    "scripts/ops/install-media-backup-systemd.sh|${PROD_ROOT}/scripts/ops/install-media-backup-systemd.sh|0755"
    "scripts/ops/install-media-health-check-systemd.sh|${PROD_ROOT}/scripts/ops/install-media-health-check-systemd.sh|0755"
    "scripts/ops/media-app-update.sh|${PROD_ROOT}/scripts/ops/media-app-update.sh|0755"
    "scripts/ops/media-backup.sh|${PROD_ROOT}/scripts/ops/media-backup.sh|0755"
    "scripts/ops/media-health-check.sh|${PROD_ROOT}/scripts/ops/media-health-check.sh|0755"
    "scripts/ops/rclone-media-sync.sh|${PROD_ROOT}/scripts/ops/rclone-media-sync.sh|0755"
    "scripts/ops/start-services.sh|${PROD_ROOT}/scripts/ops/start-services.sh|0755"
    "scripts/ops/stop-services.sh|${PROD_ROOT}/scripts/ops/stop-services.sh|0755"
    "systemd/media-firewall.service|${PROD_ROOT}/systemd/media-firewall.service|0644"
    "systemd/media-backup.service|${PROD_ROOT}/systemd/media-backup.service|0644"
    "systemd/media-backup.timer|${PROD_ROOT}/systemd/media-backup.timer|0644"
    "systemd/media-app-update.service|${PROD_ROOT}/systemd/media-app-update.service|0644"
    "systemd/media-app-update.timer|${PROD_ROOT}/systemd/media-app-update.timer|0644"
    "systemd/media-health-check.service|${PROD_ROOT}/systemd/media-health-check.service|0644"
    "systemd/media-health-check.timer|${PROD_ROOT}/systemd/media-health-check.timer|0644"
    "systemd/rclone-media-sync.service|${PROD_ROOT}/systemd/rclone-media-sync.service|0644"
    "systemd/rclone-media-sync.timer|${PROD_ROOT}/systemd/rclone-media-sync.timer|0644"
    "systemd/media-firewall.service|${SYSTEMD_ROOT}/media-firewall.service|0644"
    "systemd/media-backup.service|${SYSTEMD_ROOT}/media-backup.service|0644"
    "systemd/media-backup.timer|${SYSTEMD_ROOT}/media-backup.timer|0644"
    "systemd/media-app-update.service|${SYSTEMD_ROOT}/media-app-update.service|0644"
    "systemd/media-app-update.timer|${SYSTEMD_ROOT}/media-app-update.timer|0644"
    "systemd/media-health-check.service|${SYSTEMD_ROOT}/media-health-check.service|0644"
    "systemd/media-health-check.timer|${SYSTEMD_ROOT}/media-health-check.timer|0644"
    "systemd/rclone-media-sync.service|${SYSTEMD_ROOT}/rclone-media-sync.service|0644"
    "systemd/rclone-media-sync.timer|${SYSTEMD_ROOT}/rclone-media-sync.timer|0644"
)

if [[ "$SMARTHOME_ONLY" == true ]]; then
    managed_files=()
    for source in \
        docker/homeassistant/docker-compose.yml \
        config/homeassistant/configuration.yaml.example \
        config/env/smarthome-firewall.env.example \
        config/apparmor/homeassistant \
        config/apparmor/LICENSE.moby \
        docs/スマートホーム基盤.md \
        scripts/ops/install-smarthome-foundation.sh \
        scripts/ops/smarthome-preflight.sh \
        scripts/ops/apply-smarthome-firewall.sh \
        scripts/ops/check-smarthome-bluetooth.py \
        scripts/ops/prepare-smarthome-runtime.py \
        scripts/ops/repair-smarthome-bluetooth.sh \
        systemd/homeassistant.service \
        systemd/smarthome-apparmor.service \
        systemd/smarthome-firewall.service; do
        # 明示リストと Git 管理対象の両方に一致するファイルだけを反映。
        git -c safe.directory="$REPO_ROOT" -C "$REPO_ROOT" ls-files --error-unmatch "$source" >/dev/null
        mode=0644
        [[ $source != *.sh ]] || mode=0755
        managed_files+=("$source|${PROD_ROOT}/$source|$mode")
    done
    for name in homeassistant.service smarthome-firewall.service smarthome-apparmor.service; do
        managed_files+=("systemd/$name|${SYSTEMD_ROOT}/$name|0644")
    done
fi

if [[ "$MQTT_ONLY" == true ]]; then
    [[ "$SMARTHOME_ONLY" == false ]] || { echo 'Choose only one deployment scope.' >&2; exit 2; }
    managed_files=()
    for source in docker/mosquitto/docker-compose.yml config/mosquitto/mosquitto.conf config/mosquitto/acl \
        scripts/ops/apply-smarthome-mqtt-firewall.sh scripts/ops/install-smarthome-mqtt.sh \
        scripts/ops/smarthome_mqtt.py scripts/ops/provision-nanoc6-gateway.py \
        scripts/ops/update-nanoc6-gateway.sh scripts/ops/check-smarthome-mqtt-ha.py \
        scripts/ops/build-nanoc6-gateway.sh docs/NanoC6-MQTT連携.md \
        firmware/nanoc6/wifi_gateway/wifi_gateway.ino firmware/nanoc6/wifi_gateway/gateway_model.h \
        firmware/nanoc6/wifi_gateway/gateway_network.h firmware/nanoc6/wifi_gateway/partitions.csv \
        firmware/nanoc6/wifi_gateway/build-reference.json \
        systemd/smarthome-mqtt.service systemd/smarthome-mqtt-firewall.service; do
        git -c safe.directory="$REPO_ROOT" -C "$REPO_ROOT" ls-files --error-unmatch "$source" >/dev/null
        mode=0644
        [[ $source != *.sh ]] || mode=0755
        managed_files+=("$source|${PROD_ROOT}/$source|$mode")
    done
    for name in smarthome-mqtt.service smarthome-mqtt-firewall.service; do
        managed_files+=("systemd/$name|${SYSTEMD_ROOT}/$name|0644")
    done
fi

for entry in "${managed_files[@]}"; do
    IFS='|' read -r source destination mode <<<"$entry"
    install_managed_file "$source" "$destination" "$mode"
done

echo
echo "Host-specific files were not copied or overwritten:"
check_host_file "${PROD_ROOT}/docker/immich/.env"
check_host_file "${PROD_ROOT}/config/env/media-firewall.env"
check_host_file "${PROD_ROOT}/config/env/media-backup.env"
check_host_file "${PROD_ROOT}/config/env/media-app-update.env"
check_host_file "${PROD_ROOT}/config/env/media-health-check.env"
check_host_file "${PROD_ROOT}/config/env/notification.env"
check_host_file "${PROD_ROOT}/config/rclone/rclone.conf"
check_host_file "/mnt/data/config/rclone/rclone.conf"

echo
if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run complete. systemd daemon-reload was not executed."
elif [[ "$SYSTEMD_ROOT" != "/etc/systemd/system" ]]; then
    echo "systemd daemon-reload skipped because SYSTEMD_ROOT is $SYSTEMD_ROOT."
else
    sudo_run systemctl daemon-reload
    echo "systemd daemon reloaded."
fi

echo
echo "Deployment summary"
echo "deployed:  $COPIED"
echo "unchanged: $UNCHANGED"
echo "backups:   $BACKED_UP"
echo "backup dir: $BACKUP_DIR"
