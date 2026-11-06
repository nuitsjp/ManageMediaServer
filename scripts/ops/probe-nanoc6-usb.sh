#!/usr/bin/env bash
# Initial USB probe only. Full flash backup precedes replacement of the device FW.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
ACTION=${1:-}
[[ $# == 1 && ( $ACTION == --flash || $ACTION == --capture ) ]] \
    || { echo 'Usage: probe-nanoc6-usb.sh [--flash|--capture]' >&2; exit 2; }
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CACHE_ROOT=/home/ubuntu/.cache/manage-media-smarthome
PORT=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_9C:CC:01:33:A1:50-if00
BUILD=$CACHE_ROOT/build/nanoc6-usb-probe
TOOL=$CACHE_ROOT/arduino-data/packages/esp32/tools/esptool_py/5.1.0/esptool
CAPTURE=$REPO_ROOT/scripts/ops/capture-nanoc6-usb.py
DATA_ROOT=/mnt/data/smarthome/nanoc6
BACKUP_ROOT=/mnt/backup/smarthome/nanoc6
STAGE=preflight
fail() { echo "ERROR: $*" >&2; exit 1; }
for command in python3 logger flock sha256sum stat install; do command -v "$command" >/dev/null; done
[[ -x $TOOL && -f $CAPTURE && ! -L $CAPTURE ]] || fail 'Build tools or capture helper are missing.'
[[ -e $PORT && -c $(readlink -f "$PORT") ]] || fail "Nano C6 is not connected: $PORT"
if command -v fuser >/dev/null && fuser -s "$(readlink -f "$PORT")"; then
    fail 'The Nano C6 serial port is in use. Close other serial monitors first.'
fi
mountpoint -q /mnt/backup || fail '/mnt/backup is not mounted.'
[[ ! -L $DATA_ROOT && ! -L $BACKUP_ROOT ]] || fail 'Unexpected Nano C6 directory symlink.'
for path in /mnt/data/smarthome /mnt/backup/smarthome; do
    [[ -d $path && ! -L $path && $(stat -c %u "$path") == 0 \
        && -z $(find "$path" -maxdepth 0 -perm /022 -print) ]] || fail "Unprotected directory: $path"
done
for path in "$DATA_ROOT" "$BACKUP_ROOT" "$DATA_ROOT/diagnostics"; do
    if [[ -e $path || -L $path ]]; then
        [[ -d $path && ! -L $path && $(stat -c %u "$path") == 0 \
            && -z $(find "$path" -maxdepth 0 -perm /022 -print) ]] || fail "Unprotected directory: $path"
    else
        install -d -m 0700 -o root -g root "$path"
    fi
done
[[ ! -L $DATA_ROOT/probe.lock ]] || fail 'Unexpected lock symlink.'
exec 8>"$DATA_ROOT/probe.lock"
flock -n 8 || fail 'Another Nano C6 probe is running.'
[[ ! -L $DATA_ROOT/flashed.json ]] || fail 'Unexpected flash state symlink.'
if [[ $ACTION == --flash && -e $DATA_ROOT/flashed.json ]]; then
    fail 'A probe image was already flashed. Use --capture to preserve its Zigbee network.'
fi
if [[ $ACTION == --capture && ! -f $DATA_ROOT/flashed.json ]]; then fail 'No recorded diagnostic installation; use --flash first.'; fi
(( $(df --output=avail -k /mnt/backup | tail -1) > 128 * 1024 )) || fail 'Backup disk is too full.'
BACKUP=$(mktemp -d "$BACKUP_ROOT/usb-probe-XXXXXXXX")
OUTPUT=$(mktemp -d "$DATA_ROOT/diagnostics/usb-probe-XXXXXXXX")
cp -a "$0" "$BACKUP/probe-script.sh"
printf 'backup=%s\noutput=%s\n' "$BACKUP" "$OUTPUT"
finish() {
    local result=$?
    trap - EXIT
    printf 'stage=%s\nexit_status=%s\nbackup=%s\noutput=%s\n' \
        "$STAGE" "$result" "$BACKUP" "$OUTPUT" | tee "$OUTPUT/result.txt"
    logger -t manage-smarthome "nanoc6-usb stage=$STAGE exit_status=$result backup=$BACKUP output=$OUTPUT"
    if [[ -f $OUTPUT/report.json ]]; then
        python3 - "$OUTPUT/report.json" <<'PY'
import json, subprocess, sys
report = json.load(open(sys.argv[1]))
for device in report.get('devices', []):
    summary = {key: device.get(key) for key in ('ieee', 'manufacturer', 'model', 'complete')}
    summary['endpoints'] = {}
    for ep, data in device['endpoints'].items():
        summary['endpoints'][ep] = {'descriptor': data.get('descriptor'), 'measurements': data['measurements']}
        if not data['measurements']:
            summary['endpoints'][ep]['attributes'] = data['attributes']
    subprocess.run(['logger', '--size', '8192', '-t', 'manage-smarthome',
                    'nanoc6-usb device=' + json.dumps(summary, ensure_ascii=True)], check=True)
PY
    fi
    if (( result != 0 )); then
        echo 'No automatic reflash or rollback was attempted. Evidence and the previous flash are preserved.' >&2
        echo 'Share this output with Codex; a retry should use capture mode after a successful flash.' >&2
    fi
    exit "$result"
}
trap finish EXIT

if [[ $ACTION == --flash ]]; then
    STAGE=verify-build
    # Verify the exact tools and artifacts reviewed for this first diagnostic build.
    python3 - "$BUILD" "$TOOL" "$REPO_ROOT" <<'PY'
import hashlib, json, sys
from pathlib import Path
build, tool, root = map(Path, sys.argv[1:])
expected_tool = '9eda1f94807ce4817c17e52b452a8b5edd9d352438f27c1c638a4d86910dca1c'
expected_image = 'ec3772fd19baefe6f2a1532e639f810740dab8dadb86b20e109bea2c35d8991b'
if hashlib.sha256(tool.read_bytes()).hexdigest() != expected_tool:
    raise SystemExit('Unexpected esptool binary')
manifest = json.loads((build / 'build-manifest.json').read_text())
source = root / 'firmware/nanoc6/usb_probe/usb_probe.ino'
image = build / 'usb_probe.ino.merged.bin'
if manifest['arduino_esp32'] != '3.3.6' or manifest['flash_size'] != 4194304:
    raise SystemExit('Unexpected build settings')
if image.stat().st_size != 4194304:
    raise SystemExit('Unexpected image size')
if hashlib.sha256(source.read_bytes()).hexdigest() != manifest['source_sha256']:
    raise SystemExit('Firmware source differs from the compiled build')
if hashlib.sha256(image.read_bytes()).hexdigest() != expected_image or manifest['image_sha256'] != expected_image:
    raise SystemExit('Firmware image checksum mismatch')
PY
    cp -a "$BUILD/build-manifest.json" "$BACKUP/"
    STAGE=identify-chip
    "$TOOL" --chip esp32c6 --port "$PORT" --baud 460800 --after no-reset flash-id \
        > "$BACKUP/chip-info.txt" 2>&1
    grep -q 'Detected flash size: 4MB' "$BACKUP/chip-info.txt" || fail 'Expected a 4MB Nano C6; review chip-info.txt.'
    STAGE=backup-flash
    echo 'Backing up the complete 4 MiB Nano C6 flash before replacement...'
    "$TOOL" --chip esp32c6 --port "$PORT" --baud 460800 --after no-reset \
        read-flash 0 0x400000 "$BACKUP/original-flash.bin" > "$BACKUP/read-flash.txt" 2>&1
    [[ $(stat -c %s "$BACKUP/original-flash.bin") == 4194304 ]] || fail 'Flash backup is incomplete.'
    sha256sum "$BACKUP/original-flash.bin" | tee "$BACKUP/original-flash.sha256"
    STAGE=write-flash
    echo 'Writing the USB diagnostic image (replaces the Nano C6 firmware and stored network)...'
    "$TOOL" --chip esp32c6 --port "$PORT" --baud 460800 --after hard-reset \
        write-flash 0 "$BUILD/usb_probe.ino.merged.bin" > "$BACKUP/write-flash.txt" 2>&1
    python3 - "$BUILD/build-manifest.json" "$BACKUP" "$DATA_ROOT/flashed.json" <<'PY'
import json, sys
from pathlib import Path
state = json.loads(Path(sys.argv[1]).read_text())
state['original_flash_backup'] = sys.argv[2]
Path(sys.argv[3]).write_text(json.dumps(state, indent=2)+'\n')
PY
fi
STAGE=capture
for ((attempt=0; attempt<30; attempt++)); do [[ -e $PORT ]] && break; sleep 1; done
[[ -e $PORT ]] || fail 'USB port did not return after flashing. Reconnect without pressing the boot button.'
echo 'When READY appears, put only the TH03 being tested into Zigbee pairing mode.'
python3 "$CAPTURE" --port "$PORT" --output "$OUTPUT" --duration 300 --expected-devices 1
STAGE=complete
echo 'Device identity and temperature/humidity evidence were captured. Compare values with the TH03 display.'
