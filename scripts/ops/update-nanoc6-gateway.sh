#!/usr/bin/env bash
# USB application update preserving NVS and Zigbee storage. No automatic erasure.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CACHE=/home/ubuntu/.cache/manage-media-smarthome
BUILD=$CACHE/build/nanoc6-wifi-gateway
TOOL=$CACHE/arduino-data/packages/esp32/tools/esptool_py/5.1.0/esptool
OTA=$CACHE/arduino-data/packages/esp32/hardware/esp32/3.3.6/tools/partitions/boot_app0.bin
PORT=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_9C:CC:01:33:A1:50-if00
DATA=/mnt/data/smarthome/nanoc6
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ -x $TOOL && -f $OTA && -c $(readlink -f "$PORT") ]] || fail 'Pinned tools or Nano C6 are missing.'
mountpoint -q /mnt/backup || fail 'Backup disk is not mounted.'
for path in /mnt/data/smarthome "$DATA" /mnt/backup/smarthome /mnt/backup/smarthome/nanoc6; do
    [[ -d $path && ! -L $path && $(stat -c %u "$path") == 0 && -z $(find "$path" -maxdepth 0 -perm /022 -print) ]] || fail "Unprotected directory: $path"
done
[[ -f $DATA/probe.lock && ! -L $DATA/probe.lock && $(stat -c %u "$DATA/probe.lock") == 0 ]] || fail 'Unexpected USB lock.'
exec 8<>"$DATA/probe.lock"; flock -n 8 || fail 'Another USB operation is running.'
if command -v fuser >/dev/null && fuser -s "$(readlink -f "$PORT")"; then fail 'USB port is in use.'; fi
python3 - "$REPO" "$BUILD" "$TOOL" "$OTA" <<'PY'
import hashlib,json,sys
from pathlib import Path
repo,build,tool,ota=map(Path,sys.argv[1:])
reference=json.loads((repo/'firmware/nanoc6/wifi_gateway/build-reference.json').read_text())
manifest=json.loads((build/'build-manifest.json').read_text())
if reference['sources']!=manifest['sources'] or reference['artifacts']!=manifest['artifacts']:
    raise SystemExit('Build differs from the reviewed reference')
for name,digest in reference['sources'].items():
    if hashlib.sha256((repo/name).read_bytes()).hexdigest()!=digest: raise SystemExit('Firmware sources changed')
for name,digest in reference['artifacts'].items():
    if hashlib.sha256((build/name).read_bytes()).hexdigest()!=digest: raise SystemExit('Firmware checksum mismatch')
if hashlib.sha256(tool.read_bytes()).hexdigest()!='9eda1f94807ce4817c17e52b452a8b5edd9d352438f27c1c638a4d86910dca1c': raise SystemExit('Unexpected esptool')
if hashlib.sha256(ota.read_bytes()).hexdigest()!=reference['ota_reset_sha256']: raise SystemExit('Unexpected OTA selection image')
if (build/'wifi_gateway.ino.bin').stat().st_size>2621440: raise SystemExit('Application is too large')
PY
BACKUP=$(mktemp -d /mnt/backup/smarthome/nanoc6/gateway-update-XXXXXXXX)
cp -a "$0" "$BACKUP/update-script.sh"
cp -a "$BUILD/build-manifest.json" "$BACKUP/"
STAGE=backup
WRITING=false
finish() {
    local result=$? restored=false
    trap - EXIT
    if (( result != 0 )) && [[ $WRITING == true ]]; then
        echo 'Update failed; restoring the complete pre-update flash...' >&2
        if "$TOOL" --chip esp32c6 --port "$PORT" --after hard-reset write-flash 0 "$BACKUP/original-flash.bin" > "$BACKUP/restore.txt" 2>&1; then restored=true; fi
        echo "Flash restored: $restored. Reconnect USB without holding the button before further operation." >&2
    fi
    printf 'stage=%s\nexit_status=%s\nrestored=%s\nbackup=%s\n' "$STAGE" "$result" "$restored" "$BACKUP" | tee "$BACKUP/result.txt"
    logger -t manage-smarthome "nanoc6-update stage=$STAGE exit_status=$result restored=$restored backup=$BACKUP"
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$TOOL" --chip esp32c6 --port "$PORT" --after no-reset flash-id > "$BACKUP/chip.txt" 2>&1
grep -q 'Detected flash size: 4MB' "$BACKUP/chip.txt" || fail 'Expected ESP32-C6 with 4MB flash.'
"$TOOL" --chip esp32c6 --port "$PORT" --baud 460800 --after no-reset read-flash 0 0x400000 "$BACKUP/original-flash.bin" > "$BACKUP/read.txt" 2>&1
sha256sum "$BACKUP/original-flash.bin" > "$BACKUP/original-flash.sha256"
python3 - "$REPO" "$BACKUP/original-flash.bin" <<'PY'
import hashlib,json,sys
from pathlib import Path
repo=Path(sys.argv[1]); data=Path(sys.argv[2]).read_bytes()
r=json.loads((repo/'firmware/nanoc6/wifi_gateway/build-reference.json').read_text())
if len(data)!=4194304 or hashlib.sha256(data[0x8000:0x8c00]).hexdigest() not in r['accepted_partition_sha256']:
    raise SystemExit('Unrecognized partition table. No flash write was attempted.')
PY
STAGE=write
WRITING=true
"$TOOL" --chip esp32c6 --port "$PORT" --baud 460800 --after no-reset write-flash \
    0x8000 "$BUILD/wifi_gateway.ino.partitions.bin" 0xe000 "$OTA" 0x10000 "$BUILD/wifi_gateway.ino.bin" > "$BACKUP/write.txt" 2>&1
STAGE=readback
"$TOOL" --chip esp32c6 --port "$PORT" --baud 460800 --after hard-reset read-flash 0 0x400000 "$BACKUP/updated-flash.bin" > "$BACKUP/readback.txt" 2>&1
python3 - "$BUILD" "$BACKUP" <<'PY'
from pathlib import Path
import sys
build,backup=map(Path,sys.argv[1:])
before=(backup/'original-flash.bin').read_bytes(); after=(backup/'updated-flash.bin').read_bytes()
for start,end in ((0,0x8000),(0x9000,0xe000),(0x3ea000,0x400000)):
    if before[start:end]!=after[start:end]: raise SystemExit('Preserved storage changed; rollback required')
for start,name in ((0x8000,'wifi_gateway.ino.partitions.bin'),(0x10000,'wifi_gateway.ino.bin')):
    expected=(build/name).read_bytes()
    if after[start:start+len(expected)]!=expected: raise SystemExit('Flash readback mismatch')
print('Application verified; bootloader, NVS and Zigbee storage are unchanged.')
PY
WRITING=false
install -m 0600 -o root -g root "$BUILD/build-manifest.json" "$DATA/gateway-install.json"
STAGE=complete
echo 'Unplug the USB, wait 5 seconds, reconnect WITHOUT pressing the boot button.'
read -r -p 'Press Enter after reconnecting: ' _ || fail 'Normal power-cycle is required before provisioning.'
