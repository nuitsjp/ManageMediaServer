#!/usr/bin/env bash
set -euo pipefail
umask 027

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION="" ARCHIVE="" CHECKSUM="" CHECK_ONLY=false
forbidden_usage() {
    echo 'Usage: update.sh [--version vX.Y.Z] [--archive FILE --sha256-file FILE] [--check-only|--dry-run]' >&2
    exit 2
}
while (( $# )); do
    case "$1" in
        --version) [[ $# -ge 2 ]] || forbidden_usage; VERSION=$2; shift 2 ;;
        --archive) [[ $# -ge 2 ]] || forbidden_usage; ARCHIVE=$(realpath "$2"); shift 2 ;;
        --sha256-file) [[ $# -ge 2 ]] || forbidden_usage; CHECKSUM=$(realpath "$2"); shift 2 ;;
        --check-only|--dry-run) CHECK_ONLY=true; shift ;;
        --help|-h) echo 'Usage: update.sh [--version vX.Y.Z] [--archive FILE --sha256-file FILE] [--check-only|--dry-run]'; exit 0 ;;
        *) forbidden_usage ;;
    esac
done
[[ $EUID == 0 ]] || { echo 'Run this script with sudo.' >&2; exit 1; }
# Only the root-owned deployment configuration is sourced.
source /etc/token-monitor-analytics/deploy.env
exec 9>/run/lock/token-monitor-analytics.lock
flock -n 9 || { echo 'Another Analytics update is running.' >&2; exit 1; }
CURRENT_VERSION=""
OLD_RELEASE=$(readlink -f "$APP_ROOT/current" || true)
if [[ -f "$OLD_RELEASE/release.json" ]]; then
    CURRENT_VERSION=$(jq -r .version "$OLD_RELEASE/release.json")
fi
STATUS=failed BACKUP="" STOPPED=false TEMP="" CANDIDATE_PID="" CREATED_RELEASE=""
finish() {
    local result=$?
    trap - EXIT
    if [[ -n "$CANDIDATE_PID" ]]; then kill "$CANDIDATE_PID" 2>/dev/null || true; wait "$CANDIDATE_PID" 2>/dev/null || true; fi
    if (( result != 0 )) && [[ $STOPPED == true ]]; then
        systemctl stop token-monitor-analytics.service || true
        if [[ -n "$OLD_RELEASE" && -f "$OLD_RELEASE/release.json" ]]; then
            ln -s "$OLD_RELEASE" "$APP_ROOT/current.rollback"
            mv -Tf "$APP_ROOT/current.rollback" "$APP_ROOT/current"
            if [[ -f "$BACKUP/app.sqlite" ]]; then
                rm -f "$DATA_ROOT/app.sqlite" "$DATA_ROOT/app.sqlite-wal" "$DATA_ROOT/app.sqlite-shm"
                install -m 0640 -o mediaserver -g mediaserver "$BACKUP/app.sqlite" "$DATA_ROOT/app.sqlite"
            fi
            if ! systemctl start token-monitor-analytics.service; then
                echo 'ERROR: rollback restart failed; service remains stopped.' >&2
            fi
            echo "Restored previous distribution and DB: $OLD_RELEASE"
        fi
    fi
    if (( result != 0 )) && [[ -n "$CREATED_RELEASE" ]]; then
        if [[ -z "$OLD_RELEASE" || ! -f "$OLD_RELEASE/release.json" ]]; then
            [[ ! -L "$APP_ROOT/current" ]] || rm "$APP_ROOT/current"
        fi
        rm -rf "$CREATED_RELEASE"
    fi
    [[ -z "$TEMP" ]] || rm -rf "$TEMP"
    if [[ -n ${SUMMARY_FILE:-} ]]; then
        printf 'ANALYTICS_UPDATE_STATUS=%q\nANALYTICS_CURRENT_VERSION=%q\nANALYTICS_TARGET_VERSION=%q\n' \
            "$STATUS" "$CURRENT_VERSION" "$VERSION" > "$SUMMARY_FILE"
    fi
    exit "$result"
}
trap finish EXIT
TEMP=$(mktemp -d /mnt/data/token-monitor-analytics/update.XXXXXX)

if [[ -z "$ARCHIVE" ]]; then
    if [[ -n "$VERSION" ]]; then
        [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || forbidden_usage
        endpoint="https://api.github.com/repos/$RELEASE_REPOSITORY/releases/tags/$VERSION"
    else
        endpoint="https://api.github.com/repos/$RELEASE_REPOSITORY/releases?per_page=30"
    fi
    curl -fsSL --retry 2 --max-time 60 "$endpoint" > "$TEMP/releases.json"
    if [[ -z "$VERSION" ]]; then
        jq --arg current "$CURRENT_VERSION" '
          ($current | split(".")) as $parts |
          map(select(.draft == false and .prerelease == false and
            (.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
            (.tag_name | split("."))[0] == $parts[0] and
            (($parts[0] != "v0") or ((.tag_name | split("."))[1] == $parts[1])))) |
          sort_by(.tag_name | ltrimstr("v") | split(".") | map(tonumber)) | last
        ' "$TEMP/releases.json" > "$TEMP/release.json"
    else
        cp "$TEMP/releases.json" "$TEMP/release.json"
        jq -e '.draft == false and .prerelease == false' "$TEMP/release.json" >/dev/null
    fi
    VERSION=$(jq -r '.tag_name // empty' "$TEMP/release.json")
    if [[ -z "$VERSION" ]]; then STATUS=no_release; echo 'No eligible stable release is published.'; exit 0; fi
    if [[ -n "$CURRENT_VERSION" ]] && ! python3 - "$VERSION" "$CURRENT_VERSION" <<'PY'
import sys
def number(value): return tuple(map(int, value.lstrip('v').split('.')))
sys.exit(0 if number(sys.argv[1]) > number(sys.argv[2]) else 1)
PY
    then
        STATUS=current
        echo "Already current: $CURRENT_VERSION"
        exit 0
    fi
    if [[ $CHECK_ONLY == true ]]; then STATUS=update_available; echo "Available: $CURRENT_VERSION -> $VERSION"; exit 0; fi
    for name in token-monitor-analytics-linux-x64.tar.gz token-monitor-analytics-linux-x64.tar.gz.sha256; do
        url=$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .browser_download_url' "$TEMP/release.json")
        [[ "$url" == "https://github.com/$RELEASE_REPOSITORY/releases/download/"* ]] || { echo 'Unexpected asset URL' >&2; exit 1; }
        curl -fsSL --retry 2 --max-time 300 "$url" -o "$TEMP/$name"
    done
    ARCHIVE="$TEMP/token-monitor-analytics-linux-x64.tar.gz"
    CHECKSUM="$ARCHIVE.sha256"
fi
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && -f "$ARCHIVE" && -f "$CHECKSUM" ]] || forbidden_usage
expected=$(awk 'NR == 1 {print $1}' "$CHECKSUM")
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid checksum file' >&2; exit 1; }
[[ $(sha256sum "$ARCHIVE" | cut -d ' ' -f 1) == "$expected" ]] || { echo 'Checksum mismatch' >&2; exit 1; }
python3 "$SCRIPT_DIR/validate-package.py" "$ARCHIVE" "$TEMP/app" "$VERSION"
revision=$(jq -r .revision "$TEMP/app/release.json")
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid revision' >&2; exit 1; }
NEW_RELEASE="$APP_ROOT/releases/$VERSION-$revision"
if [[ "$OLD_RELEASE" == "$NEW_RELEASE" ]]; then STATUS=current; echo "Already installed: $VERSION ($revision)"; exit 0; fi
if [[ $CHECK_ONLY == true ]]; then STATUS=validated; echo 'Package validated; no service changes.'; exit 0; fi
mountpoint -q /mnt/backup || { echo '/mnt/backup is not mounted' >&2; exit 1; }
[[ ! -e "$NEW_RELEASE" ]] || { echo "Distribution already exists: $NEW_RELEASE" >&2; exit 1; }
install -d -m 0755 "$NEW_RELEASE"
CREATED_RELEASE="$NEW_RELEASE"
cp -a "$TEMP/app/." "$NEW_RELEASE/"
chown -R root:root "$NEW_RELEASE"
chmod -R go-w "$NEW_RELEASE"
BACKUP_TOOL="$OLD_RELEASE"
[[ -f "$BACKUP_TOOL/MultiTokenMonitor.dll" ]] || BACKUP_TOOL="$NEW_RELEASE"

# Check a cloned database before stopping production. The candidate has no public port.
install -d -m 0750 -o mediaserver -g mediaserver "$TEMP/candidate"
chmod 0750 "$TEMP"
chown root:mediaserver "$TEMP"
if [[ -f "$DATA_ROOT/app.sqlite" ]]; then
    runuser -u mediaserver -- env DB_PATH="$DATA_ROOT/app.sqlite" dotnet "$BACKUP_TOOL/MultiTokenMonitor.dll" db:backup "$TEMP/candidate/app.sqlite"
fi
runuser -u mediaserver -- env HOST=127.0.0.1 PORT=0 DB_PATH="$TEMP/candidate/app.sqlite" \
    HUB_CONFIG_PATH="$DATA_ROOT/hubs.local.json" dotnet "$NEW_RELEASE/MultiTokenMonitor.dll" > "$TEMP/candidate/output" 2>&1 &
CANDIDATE_PID=$!
ready=false
for _ in {1..30}; do
    kill -0 "$CANDIDATE_PID" 2>/dev/null || break
    url=$(sed -n 's/^AIDD_READY //p' "$TEMP/candidate/output" | head -1 | jq -r '.url // empty')
    if [[ -n "$url" ]] && curl -fsS --max-time 2 "$url/api/overview" | jq -e 'type == "object"' >/dev/null; then ready=true; break; fi
    sleep 1
done
[[ $ready == true ]] || { cat "$TEMP/candidate/output" >&2; echo 'Candidate failed' >&2; exit 1; }
kill "$CANDIDATE_PID"; wait "$CANDIDATE_PID" || true; CANDIDATE_PID=""
runuser -u mediaserver -- dotnet "$NEW_RELEASE/MultiTokenMonitor.dll" db:check "$TEMP/candidate/app.sqlite"

BACKUP="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%S)-$revision"
install -d -m 0750 -o mediaserver -g mediaserver "$BACKUP"
STOPPED=true
systemctl stop token-monitor-analytics.service
if [[ -f "$DATA_ROOT/app.sqlite" ]]; then
    runuser -u mediaserver -- env DB_PATH="$DATA_ROOT/app.sqlite" dotnet "$BACKUP_TOOL/MultiTokenMonitor.dll" db:backup "$BACKUP/app.sqlite"
    runuser -u mediaserver -- dotnet "$BACKUP_TOOL/MultiTokenMonitor.dll" db:check "$BACKUP/app.sqlite"
fi
cp -a "$CONFIG_ROOT" "$BACKUP/config"
cp -a "$DATA_ROOT/hubs.local.json" "$BACKUP/hubs.local.json"
printf '%s\n' "$OLD_RELEASE" > "$BACKUP/previous-release"
ln -s "$NEW_RELEASE" "$APP_ROOT/current.new"
mv -Tf "$APP_ROOT/current.new" "$APP_ROOT/current"
systemctl start token-monitor-analytics.service
ready=false
for _ in {1..30}; do
    if curl -fsS --max-time 2 http://127.0.0.1:13000/api/overview | jq -e 'type == "object"' >/dev/null; then ready=true; break; fi
    sleep 1
done
[[ $ready == true ]] || { echo 'Production startup failed' >&2; exit 1; }
runuser -u mediaserver -- dotnet "$NEW_RELEASE/MultiTokenMonitor.dll" db:check "$DATA_ROOT/app.sqlite"
STOPPED=false STATUS=updated
echo "Updated to $VERSION ($revision). Backup: $BACKUP"
