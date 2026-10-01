#!/usr/bin/env bash
set -euo pipefail
umask 027
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE_USER=${1:-ubuntu}
[[ "$UPDATE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo 'Invalid user name' >&2; exit 1; }
getent passwd "$UPDATE_USER" >/dev/null
mountpoint -q /mnt/backup
visudo -c
for name in update.sh validate-package.py manual-update.sh; do
    [[ -f "$REPO_ROOT/token-monitor-analytics/scripts/$name" ]]
done
[[ -f /etc/token-monitor-analytics/deploy.env ]]
[[ $(stat -c %u /etc/token-monitor-analytics/deploy.env) == 0 ]]
[[ -z $(find /etc/token-monitor-analytics/deploy.env -perm /022 -print) ]]

BACKUP=$(mktemp -d /mnt/backup/token-monitor-analytics/manual-update.XXXXXX)
chmod 0700 "$BACKUP"
TEMP=$(mktemp -d)
POLICY=/etc/sudoers.d/token-monitor-analytics-update
FILES=(/usr/local/libexec/token-monitor-analytics/update.sh
    /usr/local/libexec/token-monitor-analytics/validate-package.py
    /usr/local/sbin/token-monitor-analytics-update "$POLICY")
for file in "${FILES[@]}"; do
    [[ ! -e "$file" ]] || cp -a --parents "$file" "$BACKUP/"
done
changed=false
finish() {
    local result=$?
    trap - EXIT
    if (( result != 0 )) && [[ $changed == true ]]; then
        for file in "${FILES[@]}"; do
            if [[ -e "$BACKUP$file" ]]; then
                cp -a "$BACKUP$file" "$file"
            else
                rm -f "$file"
            fi
        done
        echo 'Restored the previous manual-update command and sudo policy.' >&2
    fi
    rm -rf "$TEMP"
    echo "Configuration backup: $BACKUP"
    exit "$result"
}
trap finish EXIT
printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/token-monitor-analytics-update\n' "$UPDATE_USER" > "$TEMP/policy"
visudo -cf "$TEMP/policy"
changed=true
install -d -m 0755 -o root -g root /usr/local/libexec /usr/local/libexec/token-monitor-analytics
install -m 0755 -o root -g root "$REPO_ROOT/token-monitor-analytics/scripts/update.sh" /usr/local/libexec/token-monitor-analytics/update.sh
install -m 0644 -o root -g root "$REPO_ROOT/token-monitor-analytics/scripts/validate-package.py" /usr/local/libexec/token-monitor-analytics/validate-package.py
install -m 0755 -o root -g root "$REPO_ROOT/token-monitor-analytics/scripts/manual-update.sh" /usr/local/sbin/token-monitor-analytics-update
install -m 0440 -o root -g root "$TEMP/policy" "$POLICY"
visudo -c
runuser -u "$UPDATE_USER" -- sudo -n -k /usr/local/sbin/token-monitor-analytics-update --help
runuser -u "$UPDATE_USER" -- sudo -n -k /usr/local/sbin/token-monitor-analytics-update --check-only
echo "Passwordless Analytics updates enabled for: $UPDATE_USER"
echo 'Command: sudo -n /usr/local/sbin/token-monitor-analytics-update [update options]'
