#!/usr/bin/env bash
# Upgrade this host to the reviewed Jellyfin 12.2 image, with a cold backup.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HELPER="$REPO_ROOT/scripts/ops/jellyfin-upgrade.py"
PROD_ROOT=/home/mediaserver/ManageMediaServer
COMPOSE="$PROD_ROOT/docker/jellyfin/docker-compose.yml"
APP_ENV="$PROD_ROOT/config/env/media-app-update.env"
APP_SCRIPT="$PROD_ROOT/scripts/ops/media-app-update.sh"
CONFIG=/mnt/data/jellyfin/config
CACHE=/mnt/data/jellyfin/cache
TARGET_VERSION=12.2
# Official multi-platform manifest, verified against Docker Hub on 2026-10-12.
TARGET_IMAGE=jellyfin/jellyfin:12.2@sha256:357724bf0ae27a672c7cbaa899db2d9abeb13dbd8657ccce750258a4c059d037
BACKUP="" TEMP="" OLD_IMAGE="" CANDIDATE=""
STOPPED=false BACKUP_READY=false CONFIG_CHANGED=false FILES_CHANGED=false
TIMER_ACTIVE=false HEALTH_TIMER_ACTIVE=false
FILES=("$COMPOSE" "$APP_ENV" "$APP_SCRIPT" "$PROD_ROOT/README.md")

compose() {
    env -u DATA_ROOT docker compose --project-directory "$(dirname "$COMPOSE")" -f "$COMPOSE" "$@"
}

wait_ready() {
    local name="$1" version="$2" attempt info
    for attempt in {1..90}; do
        if [[ $(docker inspect -f '{{.State.Running}}' "$name") != true ]]; then
            echo "ERROR: $name stopped during startup" >&2
            return 1
        fi
        # Release 12.2 reports its assembly version as 12.2.0 through this API.
        if info=$(docker exec "$name" curl -fsS --max-time 3 http://127.0.0.1:8096/System/Info/Public 2>/dev/null) \
            && jq -e --arg version "$version" '(.Version == $version or .Version == ($version + ".0")) and .StartupWizardCompleted == true' <<< "$info" >/dev/null \
            && [[ $(docker inspect -f '{{.State.Health.Status}}' "$name") == healthy ]]; then
            echo "OK: $name is healthy, version=$version; existing setup retained"
            return 0
        fi
        sleep 2
    done
    echo "ERROR: $name did not become healthy at the expected version" >&2
    return 1
}

restore_files() {
    local file
    for file in "${FILES[@]}"; do
        if [[ -f "$BACKUP$file" ]]; then cp -a "$BACKUP$file" "$file" || return 1;
        else rm -f -- "$file" || return 1; fi
    done
}

protect_database() {
    local config="$1" file
    for file in "$config/data/jellyfin.db" "$config/data/jellyfin.db-wal" "$config/data/jellyfin.db-shm"; do
        if [[ -e "$file" || -L "$file" ]]; then
            [[ -f "$file" && ! -L "$file" ]] || return 1
            chown 1001:1001 "$file" || return 1
            chmod 0600 "$file" || return 1
        fi
    done
}

rollback() {
    echo 'Restoring the previous Jellyfin deployment.' >&2
    if [[ $CONFIG_CHANGED == true ]]; then
        # Never restart the old image against a database migrated by 12.x.
        docker info >/dev/null 2>&1 || return 1
        if docker inspect jellyfin >/dev/null 2>&1; then
            docker stop -t 60 jellyfin >/dev/null || return 1
        fi
        [[ $BACKUP_READY == true ]] || { echo 'ERROR: cold backup is missing' >&2; return 1; }
        if [[ -e "$CONFIG" ]]; then mv "$CONFIG" "$BACKUP/failed-config" || return 1; fi
        if [[ -e "$CACHE" ]]; then mv "$CACHE" "$BACKUP/failed-cache" || return 1; fi
        cp -a "$BACKUP/config" "$CONFIG" || return 1
        cp -a "$BACKUP/cache" "$CACHE" || return 1
    fi
    if [[ $FILES_CHANGED == true ]]; then restore_files || return 1; fi
    if [[ $CONFIG_CHANGED == true ]]; then
        printf 'services:\n  jellyfin:\n    image: %s\n' "$ROLLBACK_IMAGE" > "$TEMP/rollback.yml"
        compose -f "$TEMP/rollback.yml" up -d --no-deps --pull never --force-recreate jellyfin || return 1
    elif [[ $STOPPED == true ]]; then
        docker start jellyfin >/dev/null || return 1
    fi
    wait_ready jellyfin "$OLD_VERSION" || return 1
    echo 'OK: previous image and original configuration/database restored.' >&2
}

finish() {
    local result=$?
    trap - EXIT
    set +e
    if [[ -n "$CANDIDATE" ]]; then
        docker logs "$CANDIDATE" > "$BACKUP/candidate.log" 2>&1
        docker rm -f "$CANDIDATE" >/dev/null 2>&1
    fi
    if (( result != 0 )) && [[ $STOPPED == true || $FILES_CHANGED == true ]]; then
        if ! rollback; then
            echo 'ERROR: rollback failed; keep Jellyfin stopped and use the protected backup.' >&2
        fi
    fi
    if [[ $TIMER_ACTIVE == true ]]; then systemctl start media-daily-maintenance.timer || result=1; fi
    if [[ $HEALTH_TIMER_ACTIVE == true ]]; then systemctl start media-health-check.timer || result=1; fi
    if [[ -n "$TEMP" ]]; then rm -rf -- "$TEMP"; fi
    echo "Upgrade exit status: $result"
    [[ -z "$BACKUP" ]] || echo "Recovery backup: $BACKUP"
    exit "$result"
}

main() {
    local file since current required_kib available_kib
    for file in "$HELPER" "$COMPOSE" "$APP_SCRIPT" "$REPO_ROOT/docker/jellyfin/docker-compose.yml"; do
        [[ -f "$file" && ! -L "$file" ]] || { echo "Missing or unexpected file: $file" >&2; return 1; }
    done
    for file in "${FILES[@]}"; do [[ ! -L "$file" ]] || { echo 'Unexpected deployment symlink' >&2; return 1; }; done
    [[ -d "$CONFIG" && ! -L "$CONFIG" && -d "$CACHE" && ! -L "$CACHE" ]]
    [[ -f "$CONFIG/data/jellyfin.db" ]]
    mountpoint -q /mnt/backup
    [[ $(docker inspect -f '{{.State.Running}}' jellyfin) == true ]]
    [[ $(docker inspect -f '{{.Config.User}}' jellyfin) == '1001:1001' ]]
    docker inspect jellyfin | jq -e '.[0].Mounts | any(.Destination == "/config" and .Source == "/mnt/data/jellyfin/config") and any(.Destination == "/cache" and .Source == "/mnt/data/jellyfin/cache")' >/dev/null
    current=$(curl -fsS --max-time 10 http://127.0.0.1:8096/System/Info/Public)
    OLD_VERSION=$(jq -er .Version <<< "$current")
    [[ "$OLD_VERSION" == 10.11.* ]] || { echo "Expected 10.11.x; review the current version before retrying: $OLD_VERSION" >&2; return 1; }
    jq -e '.StartupWizardCompleted == true' <<< "$current" >/dev/null
    OLD_IMAGE=$(docker inspect -f '{{.Image}}' jellyfin)
    [[ "$OLD_IMAGE" =~ ^sha256:[0-9a-f]{64}$ ]]

    [[ ! -L /run/manage-media-maintenance ]]
    install -d -m 0755 -o root -g root /run/manage-media-maintenance
    exec 9>/run/manage-media-maintenance/daily.lock
    flock -n 9 || { echo 'Daily maintenance is running; retry after it finishes.' >&2; return 1; }
    case $(systemctl show media-app-update.service -p ActiveState --value) in
        active|activating|deactivating) echo 'Media app update is running; retry after it finishes.' >&2; return 1 ;;
    esac
    if [[ -f /mnt/data/config/media-app-update/logs/media-app-update.lock ]]; then
        # Acquire the existing child lock read-only; do not truncate a user file.
        exec 8</mnt/data/config/media-app-update/logs/media-app-update.lock
        flock -n 8 || { echo 'Another media app update is running.' >&2; return 1; }
    fi

    BACKUP=$(mktemp -d /mnt/backup/jellyfin-upgrade.XXXXXXXX)
    chmod 0700 "$BACKUP"
    TEMP=$(mktemp -d /mnt/data/jellyfin/upgrade.XXXXXXXX)
    cp -a "$0" "$BACKUP/upgrade-script.backup.sh"
    cp -a "$HELPER" "$BACKUP/jellyfin-upgrade.py"
    for file in "${FILES[@]}"; do [[ ! -e "$file" ]] || cp -a --parents "$file" "$BACKUP/"; done
    docker inspect jellyfin > "$BACKUP/container-before.json"
    printf '%s\n' "$OLD_VERSION" > "$BACKUP/old-version"
    ROLLBACK_IMAGE="manage-media-jellyfin-rollback:$(basename "$BACKUP" | tr '[:upper:]' '[:lower:]')"
    docker tag "$OLD_IMAGE" "$ROLLBACK_IMAGE"
    printf '%s\n' "$ROLLBACK_IMAGE" > "$BACKUP/old-image-reference"
    required_kib=$(( $(docker image inspect -f '{{.Size}}' "$OLD_IMAGE") / 1024 + $(du -sk "$CONFIG" "$CACHE" | awk '{sum+=$1} END {print sum}') + 1048576 ))
    available_kib=$(df -Pk /mnt/backup | awk 'NR == 2 {print $4}')
    (( available_kib >= required_kib )) || { echo 'Insufficient backup space' >&2; return 1; }
    echo 'Downloading the reviewed image and archiving the previous image before stopping Jellyfin.'
    docker pull "$TARGET_IMAGE"
    docker image save "$ROLLBACK_IMAGE" | gzip -1 > "$BACKUP/previous-image.tar.gz"
    gzip -t "$BACKUP/previous-image.tar.gz"
    docker tag "$TARGET_IMAGE" jellyfin/jellyfin:12
    env -u DATA_ROOT docker compose -f "$REPO_ROOT/docker/jellyfin/docker-compose.yml" config -q

    if systemctl is-active --quiet media-daily-maintenance.timer; then TIMER_ACTIVE=true; fi
    if systemctl is-active --quiet media-health-check.timer; then HEALTH_TIMER_ACTIVE=true; fi
    systemctl stop media-daily-maintenance.timer media-health-check.timer
    STOPPED=true
    docker stop -t 60 jellyfin >/dev/null
    cp -a "$CONFIG" "$BACKUP/config"
    cp -a "$CACHE" "$BACKUP/cache"
    BACKUP_READY=true
    python3 "$HELPER" snapshot "$BACKUP/config" "$BACKUP/baseline.json"

    cp -a "$BACKUP/config" "$TEMP/config"
    cp -a "$BACKUP/cache" "$TEMP/cache"
    protect_database "$TEMP/config"
    python3 "$HELPER" prepare-scan "$TEMP/config" "$TEMP/scan-state.json"
    CANDIDATE="jellyfin-upgrade-$(basename "$TEMP")"
    since=$(date +%s.%N)
    docker run -d --name "$CANDIDATE" --network none --user 1001:1001 \
        --read-only --cap-drop ALL --security-opt no-new-privileges:true \
        --memory 1g --pids-limit 256 --tmpfs /tmp:rw,nosuid,nodev,size=128m \
        -e TZ=Asia/Tokyo -v "$TEMP/config:/config" -v "$TEMP/cache:/cache" \
        -v /mnt/data/jellyfin/music-videos:/media/music-videos:ro \
        -v /mnt/data/jellyfin/movies:/media/movies:ro -v /mnt/data/jellyfin/tv:/media/tv:ro \
        "$TARGET_IMAGE" >/dev/null
    wait_ready "$CANDIDATE" "$TARGET_VERSION"
    python3 "$HELPER" wait-scan "$TEMP/config" "$since"
    docker stop -t 60 "$CANDIDATE" >/dev/null
    python3 "$HELPER" verify "$BACKUP/baseline.json" "$TEMP/config"
    python3 "$HELPER" restore-scan "$TEMP/config" "$TEMP/scan-state.json"
    cp -a "$TEMP/scan-state.json" "$BACKUP/scan-state.json"
    printf '%s\n' "$since" > "$BACKUP/library-scan-start-epoch"
    echo 'OK: isolated copy migrated and scanned successfully.'

    # Promote the verified, fully scanned copy while the original stays stopped.
    # Validate it before opening the new production service to clients.
    CONFIG_CHANGED=true
    mv "$CONFIG" "$TEMP/original-config"
    mv "$CACHE" "$TEMP/original-cache"
    cp -a "$TEMP/config" "$CONFIG"
    cp -a "$TEMP/cache" "$CACHE"
    python3 "$HELPER" verify "$BACKUP/baseline.json" "$CONFIG"
    protect_database "$CONFIG"
    FILES_CHANGED=true
    install -m 0644 -o root -g root "$REPO_ROOT/docker/jellyfin/docker-compose.yml" "$COMPOSE"
    install -m 0755 -o root -g root "$REPO_ROOT/scripts/ops/media-app-update.sh" "$APP_SCRIPT"
    install -m 0644 -o root -g root "$REPO_ROOT/README.md" "$PROD_ROOT/README.md"
    python3 - "$APP_ENV" "$TEMP/app.env" <<'PY'
from pathlib import Path
import re, sys
source, output = map(Path, sys.argv[1:])
text = source.read_text() if source.exists() else ''
lines = [line for line in text.splitlines() if not re.match(r'^\s*(?:export\s+)?JELLYFIN_ALLOWED_MAJOR=', line)]
output.write_text('\n'.join(lines + ['JELLYFIN_ALLOWED_MAJOR=12']) + '\n')
PY
    install -m 0640 -o mediaserver -g mediaserver "$TEMP/app.env" "$APP_ENV"
    compose up -d --no-deps --pull never --force-recreate jellyfin
    wait_ready jellyfin "$TARGET_VERSION"
    curl -fsS --max-time 10 http://127.0.0.1:8096/health >/dev/null
    [[ $(compose config --images) == jellyfin/jellyfin:12 ]]
    grep -qx 'JELLYFIN_ALLOWED_MAJOR=12' "$APP_ENV"
    cmp -s "$REPO_ROOT/scripts/ops/media-app-update.sh" "$APP_SCRIPT"
    docker logs jellyfin > "$BACKUP/production.log" 2>&1
    printf '%s\n' "$TARGET_VERSION" > "$BACKUP/installed-version"
    STOPPED=false
    echo "OK: Jellyfin $TARGET_VERSION installed; full scan and data checks passed; daily updates allow major 12."
}

trap finish EXIT
main
