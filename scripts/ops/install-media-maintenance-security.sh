#!/usr/bin/env bash
# Install protected root entry points and data-only maintenance results.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROD_ROOT=/home/mediaserver/ManageMediaServer
ROOT_SCRIPTS=/usr/local/libexec/manage-media-maintenance
ROOT_CONFIG=/etc/manage-media-maintenance
mountpoint -q /mnt/backup || { echo '/mnt/backup is not mounted' >&2; exit 1; }
getent passwd mediaserver >/dev/null
for command in python3 jq flock systemctl; do command -v "$command" >/dev/null; done
[[ ! -L /run/manage-media-maintenance && ! -L /run/token-monitor-analytics-update ]] \
    || { echo 'Unexpected runtime directory symlink' >&2; exit 1; }
install -d -m 0755 -o root -g root /run/manage-media-maintenance
install -d -m 0700 -o root -g root /run/token-monitor-analytics-update
exec 8>/run/manage-media-maintenance/security-install.lock
flock -n 8 || { echo 'Another security installation is running' >&2; exit 1; }
# Exclude an Analytics update while its installed entry points are replaced.
# Hold both paths during migration from the previous updater.
python3 - <<'PY'
import os
try:
    fd = os.open('/run/lock/token-monitor-analytics.lock',
                 os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
except FileExistsError:
    pass
else:
    os.close(fd)
PY
[[ -f /run/lock/token-monitor-analytics.lock && ! -L /run/lock/token-monitor-analytics.lock \
    && $(stat -c %u /run/lock/token-monitor-analytics.lock) == 0 \
    && -z $(find /run/lock/token-monitor-analytics.lock -maxdepth 0 -perm /022 -print) ]] \
    || { echo 'Unexpected legacy lock permissions' >&2; exit 1; }
exec 6</run/lock/token-monitor-analytics.lock
flock -n 6 || { echo 'An Analytics update is running' >&2; exit 1; }
exec 7>/run/token-monitor-analytics-update/update.lock
flock -n 7 || { echo 'An Analytics update is running' >&2; exit 1; }

SOURCES=(scripts/ops/media-backup.sh scripts/ops/media-app-update.sh
    scripts/ops/rclone-media-sync.sh scripts/ops/media-os-update.sh
    scripts/ops/media-daily-maintenance.sh scripts/ops/read-maintenance-summary.py
    token-monitor/scripts/update.sh README.md)
TARGETS=()
for file in "${SOURCES[@]}"; do TARGETS+=("$PROD_ROOT/$file"); done
for file in media-daily-maintenance.sh media-os-update.sh read-maintenance-summary.py; do
    SOURCES+=("scripts/ops/$file")
    TARGETS+=("$ROOT_SCRIPTS/$file")
done
SOURCES+=(systemd/media-daily-maintenance.service)
TARGETS+=(/etc/systemd/system/media-daily-maintenance.service)
ANALYTICS=false
if [[ -f /etc/token-monitor-analytics/deploy.env ]]; then
    ANALYTICS=true
    for file in update.sh validate-package.py; do
        SOURCES+=("token-monitor-analytics/scripts/$file" "token-monitor-analytics/scripts/$file")
        TARGETS+=("$PROD_ROOT/token-monitor-analytics/scripts/$file" "/usr/local/libexec/token-monitor-analytics/$file")
    done
    SOURCES+=(token-monitor-analytics/scripts/manual-update.sh)
    TARGETS+=(/usr/local/sbin/token-monitor-analytics-update)
fi
for file in "${SOURCES[@]}" scripts/ops/prepare-maintenance-config.py; do
    [[ -f "$REPO_ROOT/$file" ]] || { echo "Missing source: $file" >&2; exit 1; }
done
for path in /usr/local/libexec /usr/local/sbin /usr/local/libexec/token-monitor-analytics \
    "$ROOT_SCRIPTS" "$ROOT_CONFIG" /var/log/manage-media-maintenance; do
    [[ ! -L "$path" ]] || { echo "Unexpected symlink: $path" >&2; exit 1; }
    if [[ -e "$path" ]]; then
        [[ -d "$path" && $(stat -c %u "$path") == 0 && -z $(find "$path" -maxdepth 0 -perm /022 -print) ]] \
            || { echo "Unprotected system directory: $path" >&2; exit 1; }
    fi
done
CONFIG_FILES=()
for name in media-daily-maintenance.env media-os-update.env notification.env; do
    CONFIG_FILES+=("$ROOT_CONFIG/$name")
done
for file in "${TARGETS[@]}" "${CONFIG_FILES[@]}"; do
    [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] \
        || { echo "Unexpected target type: $file" >&2; exit 1; }
done

BACKUP=$(mktemp -d /mnt/backup/media-maintenance-security.XXXXXXXX)
chmod 0700 "$BACKUP"
cp -a "$0" "$BACKUP/install-script.backup.sh"
FILES=("${TARGETS[@]}" "${CONFIG_FILES[@]}")
for file in "${FILES[@]}"; do
    if [[ -e "$file" ]]; then cp -a --parents "$file" "$BACKUP/"; fi
done
TIMER_WAS_ACTIVE=false
if systemctl is-active --quiet media-daily-maintenance.timer; then TIMER_WAS_ACTIVE=true; fi
CHANGED=false
finish() {
    local result=$?
    trap - EXIT
    if (( result != 0 )) && [[ $CHANGED == true ]]; then
        for file in "${FILES[@]}"; do
            if [[ -f "$BACKUP$file" ]]; then cp -a "$BACKUP$file" "$file";
            else rm -f -- "$file"; fi
        done
        systemctl daemon-reload || true
        echo 'Restored the previous files after installation failure.' >&2
    fi
    if [[ $TIMER_WAS_ACTIVE == true ]]; then
        if ! systemctl start media-daily-maintenance.timer; then
            echo 'ERROR: could not restore the daily timer state' >&2
            result=1
        fi
    fi
    echo "Configuration backup: $BACKUP"
    echo "Installation exit status: $result"
    exit "$result"
}
trap finish EXIT
systemctl stop media-daily-maintenance.timer
case $(systemctl show media-daily-maintenance.service -p ActiveState --value) in
    inactive|failed) ;;
    *) echo 'Daily maintenance is running; retry when it has finished.' >&2; exit 1 ;;
esac

CHANGED=true
install -d -m 0755 -o root -g root "$ROOT_SCRIPTS" /var/log/manage-media-maintenance
install -d -m 0700 -o root -g root "$ROOT_CONFIG"
for name in daily os; do
    [[ ! -L "/var/log/manage-media-maintenance/$name" ]] || { echo 'Unexpected log directory symlink' >&2; exit 1; }
    if [[ -e "/var/log/manage-media-maintenance/$name" ]]; then
        [[ -d "/var/log/manage-media-maintenance/$name" && $(stat -c %u "/var/log/manage-media-maintenance/$name") == 0 \
            && -z $(find "/var/log/manage-media-maintenance/$name" -maxdepth 0 -perm /022 -print) ]] \
            || { echo 'Unprotected log directory' >&2; exit 1; }
    fi
    install -d -m 2750 -o root -g mediaserver "/var/log/manage-media-maintenance/$name"
done
python3 "$REPO_ROOT/scripts/ops/prepare-maintenance-config.py" "$PROD_ROOT/config/env" "$ROOT_CONFIG"
chown root:root "${CONFIG_FILES[@]}"
for index in "${!SOURCES[@]}"; do
    mode=0644
    [[ ${SOURCES[index]} != *.sh ]] || mode=0755
    install -D -m "$mode" -o root -g root "$REPO_ROOT/${SOURCES[index]}" "${TARGETS[index]}"
done
systemctl daemon-reload
/usr/bin/bash "$ROOT_SCRIPTS/media-daily-maintenance.sh" --preflight
for index in "${!SOURCES[@]}"; do
    cmp -s "$REPO_ROOT/${SOURCES[index]}" "${TARGETS[index]}" || { echo 'Installed file differs from source' >&2; exit 1; }
done
for file in "$ROOT_SCRIPTS/media-daily-maintenance.sh" "$ROOT_SCRIPTS/media-os-update.sh" "${CONFIG_FILES[@]}"; do
    runuser -u mediaserver -- test ! -w "$file"
done
runuser -u mediaserver -- test ! -r "$ROOT_CONFIG/media-daily-maintenance.env"
if [[ $ANALYTICS == true ]]; then
    /usr/local/sbin/token-monitor-analytics-update --help
    /usr/bin/bash /usr/local/libexec/token-monitor-analytics/update.sh --help
    if /usr/local/sbin/token-monitor-analytics-update --archive /nonexistent --sha256-file /nonexistent; then
        echo 'ERROR: local package arguments were accepted' >&2
        exit 1
    else
        [[ $? == 2 ]] || { echo 'ERROR: unexpected rejection status' >&2; exit 1; }
    fi
    visudo -c
    echo 'OK: passwordless entry point rejects caller-supplied packages.'
fi
echo 'OK: protected root scripts/configuration and maintenance preflight.'
echo 'No maintenance steps, application updates, or reboots were run.'
