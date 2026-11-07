#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CACHE=${NANOC6_CACHE_ROOT:-/home/ubuntu/.cache/manage-media-smarthome}
BUILD=$CACHE/build/nanoc6-wifi-gateway
FQBN=esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=4M,PartitionScheme=zigbee_zczr,ZigbeeMode=zczr
[[ -x $CACHE/toolchain/arduino-cli && -f $CACHE/toolchain/arduino-cli.yaml ]] || { echo 'Pinned toolchain missing.' >&2; exit 1; }
"$CACHE/toolchain/arduino-cli" --config-file "$CACHE/toolchain/arduino-cli.yaml" core list --format json | python3 -c '
import json,sys
assert any(p.get("id")=="esp32:esp32" and p.get("installed_version")=="3.3.6" for p in json.load(sys.stdin)["platforms"]), "Need Arduino-ESP32 3.3.6"
'
"$CACHE/toolchain/arduino-cli" --config-file "$CACHE/toolchain/arduino-cli.yaml" compile \
    --fqbn "$FQBN" --build-property upload.maximum_size=2621440 --jobs 1 --build-path "$BUILD" \
    "$REPO/firmware/nanoc6/wifi_gateway"
python3 - "$REPO" "$BUILD" "$FQBN" <<'PY'
import hashlib,json,sys
from pathlib import Path
repo,build=map(Path,sys.argv[1:3])
sources=repo/'firmware/nanoc6/wifi_gateway'
report={'arduino_esp32':'3.3.6','fqbn':sys.argv[3], 'app_offset':65536, 'app_max_size':2621440,
        'preserved_ranges':[[36864,20480],[4104192,20480]],
        'sources':{str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources.iterdir()) if p.is_file() and p.suffix in ('.ino','.h','.csv')},
        'artifacts':{name:hashlib.sha256((build/name).read_bytes()).hexdigest() for name in
                     ('wifi_gateway.ino.bin','wifi_gateway.ino.partitions.bin')}}
(build/'build-manifest.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
PY
