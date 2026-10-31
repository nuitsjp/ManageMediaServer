#!/usr/bin/env bash
# 初回導入専用。既存 HA データの移行・アップグレードには使わない。
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $# == 0 ]] || { echo 'Usage: install-smarthome-foundation.sh' >&2; exit 2; }
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROD_ROOT=/home/mediaserver/ManageMediaServer
DATA_ROOT=/mnt/data/smarthome
DATA_DIR=$DATA_ROOT/homeassistant
BACKUP_ROOT=/mnt/backup/smarthome
ROOT_CONFIG=/etc/manage-smarthome
ROOT_SCRIPTS=/usr/local/libexec/manage-smarthome
COMPOSE=$PROD_ROOT/docker/homeassistant/docker-compose.yml
LAN_IFACE=enp1s0
LAN_CIDR=192.168.0.0/24
STAGE=preflight

fail() { echo "ERROR: $*" >&2; exit 1; }
for command in docker python3 iptables ip6tables curl runuser flock git apt-get; do
    command -v "$command" >/dev/null || fail "Missing command: $command"
done
for source in scripts/ops/deploy-managed-files.sh scripts/ops/apply-smarthome-firewall.sh \
    scripts/ops/smarthome-preflight.sh docker/homeassistant/docker-compose.yml \
    config/homeassistant/configuration.yaml.example config/env/smarthome-firewall.env.example \
    systemd/homeassistant.service systemd/smarthome-firewall.service docs/スマートホーム基盤.md; do
    [[ -f $REPO_ROOT/$source ]] || fail "Missing source: $source"
    git -c safe.directory="$REPO_ROOT" -C "$REPO_ROOT" ls-files --error-unmatch "$source" >/dev/null
done
[[ $(uname -m) == x86_64 ]] || fail 'The pinned image is for x86_64.'
mountpoint -q /mnt/backup || fail '/mnt/backup is not mounted.'
getent passwd mediaserver >/dev/null || fail 'mediaserver user is missing.'
id -nG mediaserver | tr ' ' '\n' | grep -qx docker || fail 'mediaserver must already belong to docker.'
[[ -S /run/dbus/system_bus_socket ]] || fail 'Host D-Bus is not available.'
[[ -d /sys/class/net/$LAN_IFACE ]] || fail "LAN interface is missing: $LAN_IFACE"
ip -4 -o addr show dev "$LAN_IFACE" | grep -q '192\.168\.0\.23/' || fail 'LAN address changed; review the firewall settings.'
for path in "$PROD_ROOT" /mnt /mnt/data /mnt/backup "$DATA_ROOT" "$BACKUP_ROOT" \
    "$ROOT_CONFIG" "$ROOT_SCRIPTS" /run/manage-smarthome /run/manage-media-maintenance; do
    [[ ! -L $path ]] || fail "Unexpected symlink: $path"
    [[ ! -e $path || -d $path ]] || fail "Not a directory: $path"
done
[[ ! -e $DATA_ROOT ]] || fail "$DATA_ROOT already exists. This installer is for a fresh installation."
for unit in homeassistant.service smarthome-firewall.service; do
    [[ $(systemctl show "$unit" -p LoadState --value) == not-found ]] || fail "Unit already exists: $unit"
done
[[ -z $(docker ps -a --filter name='^/homeassistant$' -q) ]] || fail 'homeassistant container already exists.'
[[ -z $(ss -H -ltn 'sport = :8123') ]] || fail 'TCP 8123 is already in use.'
for tool in iptables ip6tables; do
    if "$tool" -w 10 -S MMS-SMARTHOME >/dev/null 2>&1; then fail 'Smart home firewall chain already exists.'; fi
done
for path in /usr/local/libexec "$ROOT_CONFIG" "$ROOT_SCRIPTS" /run/manage-smarthome /run/manage-media-maintenance; do
    if [[ -e $path ]]; then
        [[ $(stat -c %u "$path") == 0 && -z $(find "$path" -maxdepth 0 -perm /022 -print) ]] \
            || fail "Unprotected root directory: $path"
    fi
done
(( $(df --output=avail -k / | tail -1) > 10 * 1024 * 1024 )) || fail 'Less than 10 GiB free on root.'
(( $(df --output=avail -k /mnt/backup | tail -1) > 2 * 1024 * 1024 )) || fail 'Less than 2 GiB free on backup.'
install -d -m 0700 -o root -g root /run/manage-smarthome
exec 8>/run/manage-smarthome/install.lock
flock -n 8 || fail 'Another smart home installation is running.'
# 既存日次処理と同じ lock。OS 更新との競合を避け、timer 自体は変更しない。
install -d -m 0755 -o root -g root /run/manage-media-maintenance
[[ ! -L /run/manage-media-maintenance/daily.lock ]] || fail 'Unexpected maintenance lock symlink.'
exec 9>/run/manage-media-maintenance/daily.lock
flock -n 9 || fail 'Daily maintenance is running. Retry after it finishes.'

install -d -m 0700 -o root -g root "$BACKUP_ROOT"
BACKUP=$(mktemp -d "$BACKUP_ROOT/install-XXXXXXXX")
echo "Installation backup and results: $BACKUP"
install -d -m 0700 "$BACKUP/files"
cp -a "$0" "$BACKUP/installer.sh"
"$REPO_ROOT/scripts/ops/smarthome-preflight.sh" > "$BACKUP/preflight-before.txt" 2>&1
dpkg-query -W -f='${Package} ${Version}\n' > "$BACKUP/packages-before.txt"
UNITS=(homeassistant.service smarthome-firewall.service)
TARGETS=("$ROOT_SCRIPTS/apply-smarthome-firewall.sh" "$ROOT_CONFIG/firewall.env")
for file in docker/homeassistant/docker-compose.yml config/homeassistant/configuration.yaml.example \
    config/env/smarthome-firewall.env.example docs/スマートホーム基盤.md \
    scripts/ops/install-smarthome-foundation.sh scripts/ops/smarthome-preflight.sh \
    scripts/ops/apply-smarthome-firewall.sh systemd/homeassistant.service systemd/smarthome-firewall.service; do
    TARGETS+=("$PROD_ROOT/$file")
done
for unit in "${UNITS[@]}"; do TARGETS+=("/etc/systemd/system/$unit"); done
for file in "${TARGETS[@]}"; do
    [[ ! -L $file && ( ! -e $file || -f $file ) ]] || fail "Unexpected target type: $file"
    if [[ -f $file ]]; then cp -a --parents "$file" "$BACKUP/files"; fi
done
EXISTING=()
for name in immich jellyfin token-monitor token-monitor-public token-monitor-analytics token-monitor-analytics-http; do
    if systemctl is-active --quiet "$name"; then EXISTING+=("$name"); fi
done
docker ps -q | sort > "$BACKUP/containers-before.txt"
BLUEZ_WAS_ACTIVE=false
BLUEZ_WAS_ENABLED=false
systemctl is-active --quiet bluetooth && BLUEZ_WAS_ACTIVE=true
systemctl is-enabled --quiet bluetooth 2>/dev/null && BLUEZ_WAS_ENABLED=true
CHANGED=false
rollback_command() {
    if ! "$@"; then
        ROLLBACK_FAILED=true
        printf 'ROLLBACK ERROR: %q ' "$@" >&2
        printf '\n' >&2
    fi
}
finish() {
    local result=$?
    local ROLLBACK_FAILED=false remaining
    trap - EXIT
    if (( result != 0 )) && [[ $CHANGED == true ]]; then
        echo "Installation failed in $STAGE; rolling back smart home services." >&2
        rollback_command systemctl disable --now homeassistant.service smarthome-firewall.service
        rollback_command docker compose -f "$REPO_ROOT/docker/homeassistant/docker-compose.yml" down --remove-orphans
        rollback_command /usr/bin/bash "$REPO_ROOT/scripts/ops/apply-smarthome-firewall.sh" remove
        for file in "${TARGETS[@]}"; do
            if [[ -f $BACKUP/files$file ]]; then rollback_command cp -a "$BACKUP/files$file" "$file";
            else rollback_command rm -f -- "$file"; fi
        done
        if [[ -d $DATA_ROOT ]]; then
            # 診断データを秘密情報ごと保持する。自動削除しない。
            if remaining=$(docker ps -q --filter name='^/homeassistant$') && [[ -z $remaining ]]; then
                rollback_command mv "$DATA_ROOT" "$BACKUP/failed-data"
            else
                ROLLBACK_FAILED=true
                echo "Cannot confirm HA is stopped; keeping $DATA_ROOT in place." >&2
            fi
        fi
        rollback_command systemctl daemon-reload
        if [[ $BLUEZ_WAS_ACTIVE == false ]] && systemctl cat bluetooth >/dev/null 2>&1; then
            rollback_command systemctl stop bluetooth
        fi
        if [[ $BLUEZ_WAS_ENABLED == false ]] && systemctl cat bluetooth >/dev/null 2>&1; then
            rollback_command systemctl disable bluetooth
        fi
        echo 'BlueZ packages and downloaded images remain installed; existing applications were not rolled back.' >&2
    fi
    printf 'stage=%s\nexit_status=%s\nrollback_failed=%s\nbackup=%s\n' \
        "$STAGE" "$result" "$ROLLBACK_FAILED" "$BACKUP" | tee "$BACKUP/result.txt"
    exit "$result"
}
trap finish EXIT

STAGE=image-pull
# 事前にイメージを取得し、タグが動いても同一 digest で起動する。
docker compose -f "$REPO_ROOT/docker/homeassistant/docker-compose.yml" pull
STAGE=deploy
CHANGED=true
PROD_ROOT="$PROD_ROOT" BACKUP_PARENT="$BACKUP/managed-files" \
    /usr/bin/bash "$REPO_ROOT/scripts/ops/deploy-managed-files.sh" --smarthome-only
install -d -m 0700 -o root -g root "$DATA_ROOT" "$DATA_DIR" "$ROOT_CONFIG"
install -d -m 0755 -o root -g root "$ROOT_SCRIPTS"
install -m 0755 -o root -g root "$REPO_ROOT/scripts/ops/apply-smarthome-firewall.sh" "$ROOT_SCRIPTS/"
install -m 0600 -o root -g root "$REPO_ROOT/config/env/smarthome-firewall.env.example" "$ROOT_CONFIG/firewall.env"
install -m 0600 -o root -g root "$REPO_ROOT/config/homeassistant/configuration.yaml.example" "$DATA_DIR/configuration.yaml"
printf '[]\n' > "$DATA_DIR/automations.yaml"
printf '{}\n' > "$DATA_DIR/scripts.yaml"
printf '[]\n' > "$DATA_DIR/scenes.yaml"
STAGE=bluetooth
# BlueZ のみ追加。ホスト全体の更新・D-Bus 実装の交換は行わない。
if ! dpkg-query -W -f='${Status}' bluez 2>/dev/null | grep -qx 'install ok installed'; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends bluez
fi
systemctl enable --now bluetooth
timeout 20 bluetoothctl power on
timeout 20 bluetoothctl show > "$BACKUP/bluetooth.txt"
grep -q 'Controller ' "$BACKUP/bluetooth.txt" || fail 'BlueZ cannot see a Bluetooth controller.'
grep -q 'Powered: yes' "$BACKUP/bluetooth.txt" || fail 'The Bluetooth controller is not powered.'
STAGE=config-check
# 独立コンテナで設定検証。運用コンテナを二重起動しない。
docker compose -f "$COMPOSE" run --rm --no-deps --entrypoint python3 homeassistant \
    -m homeassistant --script check_config --config /config > "$BACKUP/config-check.txt" 2>&1
STAGE=start
systemctl daemon-reload
systemctl enable --now smarthome-firewall.service
systemctl enable --now homeassistant.service
STAGE=verify
ready=false
for ((attempt=0; attempt<90; attempt++)); do
    if curl --fail --silent --max-time 5 http://127.0.0.1:8123/ -o /dev/null \
        && [[ $(docker inspect -f '{{.State.Health.Status}}' homeassistant) == healthy ]]; then
        ready=true
        break
    fi
    sleep 5
done
[[ $ready == true ]] || fail 'HA did not respond within the startup window.'
for name in homeassistant smarthome-firewall bluetooth; do
    systemctl is-active --quiet "$name" || fail "Required service is not active: $name"
done
LAN_IFACE="$LAN_IFACE" LAN_CIDR="$LAN_CIDR" \
    /usr/bin/bash "$ROOT_SCRIPTS/apply-smarthome-firewall.sh" status > "$BACKUP/firewall.txt"
for name in "${EXISTING[@]}"; do systemctl is-active --quiet "$name" || fail "Existing service stopped: $name"; done
while IFS= read -r container; do
    [[ $(docker inspect -f '{{.State.Running}}' "$container") == true ]] || fail "Existing container stopped: $container"
done < "$BACKUP/containers-before.txt"
"$REPO_ROOT/scripts/ops/smarthome-preflight.sh" > "$BACKUP/preflight-after.txt" 2>&1
docker inspect -f 'image={{.Config.Image}} status={{.State.Status}} health={{.State.Health.Status}}' \
    homeassistant | tee "$BACKUP/homeassistant.txt"
STAGE=complete
echo 'Home Assistant is running: http://192.168.0.23:8123/'
echo 'Complete owner account setup and MFA in your browser. Device pairing and reboot testing are still pending.'
echo 'HA data is not backed up on a schedule yet; configure encrypted backups before production use.'
