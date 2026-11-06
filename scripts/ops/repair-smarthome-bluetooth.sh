#!/usr/bin/env bash
# 既設基盤へ HA 専用 AppArmor を反映する。HA データ・認証・版は変更しない。
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $# == 0 ]] || { echo 'Usage: repair-smarthome-bluetooth.sh' >&2; exit 2; }
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROD_ROOT=/home/mediaserver/ManageMediaServer
COMPOSE=$PROD_ROOT/docker/homeassistant/docker-compose.yml
AA_FILE=/etc/apparmor.d/manage-smarthome-homeassistant
CHECKER=$REPO_ROOT/scripts/ops/check-smarthome-bluetooth.py
PROFILE=manage-smarthome-homeassistant
load_apparmor_profile() {
    # RemainAfterExit の oneshot は enable --now では再実行されない。
    # profile ファイル更新後は、起動済みの場合も必ず parser を再実行する。
    systemctl enable smarthome-apparmor.service
    systemctl restart smarthome-apparmor.service
    systemctl is-active --quiet smarthome-apparmor.service
}
fail() { echo "ERROR: $*" >&2; exit 1; }
for command in docker apparmor_parser python3 curl git flock systemctl logger; do
    command -v "$command" >/dev/null || fail "Missing command: $command"
done
mountpoint -q /mnt/backup || fail '/mnt/backup is not mounted.'
[[ -d /mnt/data/smarthome/homeassistant && -f $COMPOSE ]] || fail 'HA foundation is missing.'
for unit in homeassistant smarthome-firewall bluetooth; do
    systemctl is-active --quiet "$unit" || fail "Service is not active: $unit"
done
RUNTIME_HELPER=$REPO_ROOT/scripts/ops/prepare-smarthome-runtime.py
[[ -f $RUNTIME_HELPER && ! -L $RUNTIME_HELPER ]] || fail 'Runtime preparation helper is missing or a symlink.'
python3 "$RUNTIME_HELPER"
for path in /run/manage-smarthome /run/manage-media-maintenance /mnt/backup/smarthome /etc/apparmor.d; do
    [[ -d $path && ! -L $path && $(stat -c %u "$path") == 0 \
        && -z $(find "$path" -maxdepth 0 -perm /022 -print) ]] || fail "Unprotected directory: $path"
done
exec 8<>/run/manage-smarthome/install.lock
flock -n 8 || fail 'Another smart home operation is running.'
[[ ! -L /run/manage-media-maintenance/daily.lock ]] || fail 'Unexpected maintenance lock symlink.'
exec 9<>/run/manage-media-maintenance/daily.lock
flock -n 9 || fail 'Daily maintenance is running; retry after it finishes.'
(( $(df --output=avail -k /mnt/backup | tail -1) > 1024 * 1024 )) || fail 'Less than 1 GiB free on backup.'
FILES=(docker/homeassistant/docker-compose.yml config/homeassistant/configuration.yaml.example
    config/env/smarthome-firewall.env.example config/apparmor/homeassistant config/apparmor/LICENSE.moby
    docs/スマートホーム基盤.md scripts/ops/install-smarthome-foundation.sh
    scripts/ops/smarthome-preflight.sh scripts/ops/apply-smarthome-firewall.sh
    scripts/ops/check-smarthome-bluetooth.py scripts/ops/repair-smarthome-bluetooth.sh
    scripts/ops/prepare-smarthome-runtime.py
    systemd/homeassistant.service systemd/smarthome-firewall.service systemd/smarthome-apparmor.service)
for source in "${FILES[@]}" scripts/ops/deploy-managed-files.sh; do
    [[ -f $REPO_ROOT/$source && ! -L $REPO_ROOT/$source ]] || fail "Missing or unexpected source: $source"
    git -c safe.directory="$REPO_ROOT" -C "$REPO_ROOT" ls-files --error-unmatch "$source" >/dev/null
done
apparmor_parser -Q -K "$REPO_ROOT/config/apparmor/homeassistant"
expected_image=$(docker compose -f "$REPO_ROOT/docker/homeassistant/docker-compose.yml" config --images)
[[ $(docker inspect -f '{{.Config.Image}}' homeassistant) == "$expected_image" ]] || fail 'HA image differs; review before changing it.'
BACKUP=$(mktemp -d /mnt/backup/smarthome/bluetooth-repair-XXXXXXXX)
install -d -m 0700 "$BACKUP/files"
cp -a "$0" "$BACKUP/repair.sh"
TARGETS=("$AA_FILE")
for source in "${FILES[@]}"; do TARGETS+=("$PROD_ROOT/$source"); done
for unit in homeassistant smarthome-firewall smarthome-apparmor; do
    TARGETS+=("/etc/systemd/system/$unit.service")
done
for file in "${TARGETS[@]}"; do
    [[ ! -L $file && ( ! -e $file || -f $file ) ]] || fail "Unexpected target: $file"
    if [[ -f $file ]]; then cp -a --parents "$file" "$BACKUP/files/"; fi
done
AA_WAS_ENABLED=false
systemctl is-enabled --quiet smarthome-apparmor.service 2>/dev/null && AA_WAS_ENABLED=true
docker ps --format '{{.ID}} {{.Names}}' | awk '$2 != "homeassistant" {print $1}' > "$BACKUP/other-containers.txt"
STAGE=prepare
CHANGED=false
finish() {
    local result=$? rollback_failed=false
    trap - EXIT
    if (( result != 0 )) && [[ $CHANGED == true ]]; then
        echo "Repair failed in $STAGE; restoring the previous HA configuration." >&2
        if systemctl stop homeassistant; then
            if [[ $AA_WAS_ENABLED == false ]]; then systemctl disable --now smarthome-apparmor || rollback_failed=true; fi
            # 旧構成が独自 profile を使う場合は復元して再ロードする。初回修正失敗時は追加分を解除。
            if [[ ! -f $BACKUP/files$AA_FILE ]] && [[ -f $AA_FILE ]] \
                && grep -q "^$PROFILE " /sys/kernel/security/apparmor/profiles; then
                apparmor_parser -R "$AA_FILE" || rollback_failed=true
            fi
            for file in "${TARGETS[@]}"; do
                if [[ -f $BACKUP/files$file ]]; then cp -a "$BACKUP/files$file" "$file" || rollback_failed=true;
                else rm -f -- "$file" || rollback_failed=true; fi
            done
            if [[ -f $AA_FILE ]]; then apparmor_parser -r -W "$AA_FILE" || rollback_failed=true; fi
            systemctl daemon-reload || rollback_failed=true
            systemctl start homeassistant || rollback_failed=true
        else
            rollback_failed=true
            echo 'Cannot stop HA; leaving the AppArmor policy loaded and files intact for manual recovery.' >&2
        fi
    fi
    printf 'stage=%s\nexit_status=%s\nrollback_failed=%s\nbackup=%s\n' \
        "$STAGE" "$result" "$rollback_failed" "$BACKUP" | tee "$BACKUP/result.txt"
    logger -t manage-smarthome "bluetooth-repair stage=$STAGE exit_status=$result rollback_failed=$rollback_failed backup=$BACKUP"
    exit "$result"
}
trap finish EXIT
CHANGED=true
STAGE=stop-ha
systemctl stop homeassistant
STAGE=deploy
PROD_ROOT="$PROD_ROOT" BACKUP_PARENT="$BACKUP/managed-files" \
    /usr/bin/bash "$REPO_ROOT/scripts/ops/deploy-managed-files.sh" --smarthome-only
install -m 0644 -o root -g root "$REPO_ROOT/config/apparmor/homeassistant" "$AA_FILE"
STAGE=apparmor-load
systemctl daemon-reload
load_apparmor_profile
logger -t manage-smarthome 'Home Assistant AppArmor profile reloaded before HA startup.'
STAGE=start
VERIFY_SINCE=$(date -u '+%Y-%m-%d %H:%M:%S.%6N UTC')
systemctl start homeassistant
STAGE=verify
ready=false
for ((attempt=0; attempt<60; attempt++)); do
    if curl --fail --silent --max-time 5 http://127.0.0.1:8123/ -o /dev/null \
        && [[ $(docker inspect -f '{{.State.Health.Status}}' homeassistant) == healthy ]]; then
        ready=true
        break
    fi
    sleep 5
done
[[ $ready == true ]] || fail 'HA HTTP/health verification failed.'
bluetooth_ready=false
for ((attempt=0; attempt<3; attempt++)); do
    if docker exec -i homeassistant python3 - < "$CHECKER" > "$BACKUP/bluetooth-container.json" 2>&1; then
        bluetooth_ready=true
        break
    fi
    # Probe は認証情報や機器の識別情報を出力しない。失敗も journal から確認可能にする。
    logger -t manage-smarthome "Bluetooth probe attempt=$((attempt+1)): $(head -c 1024 "$BACKUP/bluetooth-container.json")"
    sleep 5
done
cat "$BACKUP/bluetooth-container.json" 2>/dev/null || true
logger -t manage-smarthome "Bluetooth live probe: $(head -c 1024 "$BACKUP/bluetooth-container.json")"
[[ $bluetooth_ready == true ]] || fail 'HA live Bluetooth reception verification failed.'
[[ $(docker inspect -f '{{.AppArmorProfile}}' homeassistant) == "$PROFILE" ]] || fail 'Wrong AppArmor profile.'
# 実際の受信に成功しても、別の通知が拒否されていないか確認する。
sleep 10
journalctl -k --since "$VERIFY_SINCE" --no-pager -o cat > "$BACKUP/apparmor-audit.txt"
if grep -q "apparmor=\"DENIED\".*label=\"$PROFILE\"" "$BACKUP/apparmor-audit.txt"; then
    fail 'AppArmor still denies HA operations. See apparmor-audit.txt in the backup directory.'
fi
for unit in homeassistant smarthome-firewall smarthome-apparmor bluetooth; do
    systemctl is-active --quiet "$unit" || fail "Service stopped: $unit"
done
for name in immich jellyfin; do systemctl is-active --quiet "$name" || fail "Existing service stopped: $name"; done
while IFS= read -r container; do
    [[ $(docker inspect -f '{{.State.Running}}' "$container") == true ]] || fail "Existing container stopped: $container"
done < "$BACKUP/other-containers.txt"
curl --fail --silent --max-time 10 http://127.0.0.1:2283/ -o /dev/null
curl --fail --silent --max-time 10 http://127.0.0.1:8096/health -o /dev/null
STAGE=complete
logger -t manage-smarthome "Bluetooth container check: $(cat "$BACKUP/bluetooth-container.json")"
echo 'Home Assistant Bluetooth verified. Owner account setup, real sensor reception and reboot/LAN client tests remain separate.'
