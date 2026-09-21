#!/usr/bin/env bash

set -euo pipefail

DATA_ROOT="${TOKEN_MONITOR_DATA_ROOT:-/mnt/data/token-monitor}"
BACKUP_ROOT="${TOKEN_MONITOR_BACKUP_ROOT:-/mnt/backup/token-monitor}"
STAMP=$(date '+%Y%m%d-%H%M%S')
DEST="${BACKUP_ROOT}/${STAMP}"

[[ -d /mnt/backup ]] || { echo "ERROR: /mnt/backup is missing" >&2; exit 1; }
mountpoint -q /mnt/backup || { echo "ERROR: /mnt/backup is not a mountpoint" >&2; exit 1; }

mkdir -p "$DEST/private" "$DEST/work" "$DEST/agent-private"

agent_was_running=false
if command -v docker >/dev/null \
    && [[ "$(docker inspect -f '{{.State.Running}}' token-monitor-agent-private 2>/dev/null || true)" == "true" ]]; then
    agent_was_running=true
    docker stop token-monitor-agent-private >/dev/null
fi

restart_agent() {
    if [[ "$agent_was_running" == "true" ]]; then
        docker start token-monitor-agent-private >/dev/null
    fi
}
trap restart_agent EXIT

copy_if_present() {
    local source="$1"
    local destination="$2"
    if [[ -f "$source" ]]; then
        cp -a "$source" "$destination/"
        echo "BACKUP: $source"
    else
        echo "SKIP: $source does not exist yet"
    fi
}

copy_if_present "${DATA_ROOT}/private/data/devices.json" "$DEST/private"
copy_if_present "${DATA_ROOT}/work/data/devices.json" "$DEST/work"

if [[ -d "${DATA_ROOT}/agent-private/state" ]]; then
    cp -a "${DATA_ROOT}/agent-private/state/." "$DEST/agent-private/"
    echo "BACKUP: ${DATA_ROOT}/agent-private/state"
fi

printf '%s\n' "$DEST" > "${BACKUP_ROOT}/latest-backup.txt"
restart_agent
agent_was_running=false
echo "Token Monitor backup completed: $DEST"
