#!/usr/bin/env bash
# Uses the pinned user-local toolchain. Never installs system packages.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CACHE_ROOT=${NANOC6_CACHE_ROOT:-/home/ubuntu/.cache/manage-media-smarthome}
CLI=$CACHE_ROOT/toolchain/arduino-cli
CONFIG=$CACHE_ROOT/toolchain/arduino-cli.yaml
BUILD=$CACHE_ROOT/build/nanoc6-usb-probe
FQBN=esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=4M,PartitionScheme=zigbee_zczr,ZigbeeMode=zczr
[[ -x $CLI && -f $CONFIG ]] || { echo 'Pinned Arduino CLI/configuration are missing; see the Nano C6 runbook.' >&2; exit 1; }
"$CLI" --config-file "$CONFIG" core list --format json | python3 -c '
import json, sys
platforms = json.load(sys.stdin).get("platforms", [])
if not any(p.get("id") == "esp32:esp32" and p.get("installed_version") == "3.3.6" for p in platforms):
    raise SystemExit("Arduino-ESP32 3.3.6 must be installed")
'
"$CLI" --config-file "$CONFIG" compile --fqbn "$FQBN" --jobs 1 --build-path "$BUILD" \
    "$REPO_ROOT/firmware/nanoc6/usb_probe"
python3 - "$REPO_ROOT" "$BUILD" "$FQBN" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, build = map(Path, sys.argv[1:3])
image = build / 'usb_probe.ino.merged.bin'
report = {'arduino_esp32': '3.3.6', 'fqbn': sys.argv[3], 'flash_size': 4194304,
          'image_sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
          'source_sha256': hashlib.sha256((root / 'firmware/nanoc6/usb_probe/usb_probe.ino').read_bytes()).hexdigest()}
(build / 'build-manifest.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
PY
