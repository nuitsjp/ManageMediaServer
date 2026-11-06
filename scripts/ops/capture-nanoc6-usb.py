#!/usr/bin/env python3
"""Capture Nano C6 USB probe events using Linux's serial interface (stdlib only)."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import select
import sys
import termios
import time

# Verified converter behavior in zigbee-herdsman-converters/src/devices/{tuya,sonoff}.ts.
# Never infer a scale from a value that merely looks plausible.
HUMIDITY_DIVISORS = {
    ('TS0201', '_TZ3000_bguser20'): 100,
    ('TS0201', '_TZ3000_xr3htd96'): 100,
    ('TS0201', '_TZ3000_itnrsufe'): 10,
    ('TH01', 'Zbeacon'): 100,
}


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def zcl_string(raw):
    if not raw or raw[0] == 0xff or raw[0] > len(raw) - 1:
        raise ValueError('Invalid ZCL string')
    return raw[1:1 + raw[0]].decode('utf-8', errors='strict')


class Evidence:
    def __init__(self):
        self.devices = {}
        self.event_drops = 0
        self.job_drops = 0

    def accept(self, event, received_at=None):
        if event.get('v') != 1:
            raise ValueError('Unsupported event version')
        self.event_drops = max(self.event_drops, int(event.get('event_drops', 0)))
        self.job_drops = max(self.job_drops, int(event.get('job_drops', 0)))
        if event.get('event') not in ('attribute', 'descriptor', 'announce', 'custom'):
            return
        ieee = event.get('ieee', '')
        if not re.fullmatch(r'[0-9a-f]{16}', ieee) or ieee == '0000000000000000':
            return  # No identity -> evidence remains in the raw log, never merged into a sensor.
        device = self.devices.setdefault(ieee, {'ieee': ieee, 'endpoints': {}, 'manufacturer': None, 'model': None})
        device['short'] = event.get('short')
        endpoint = str(event.get('endpoint'))
        ep = device['endpoints'].setdefault(endpoint, {'attributes': {}})
        if event['event'] == 'descriptor':
            ep['descriptor'] = {key: event.get(key) for key in ('profile', 'device', 'in_clusters', 'out_clusters', 'truncated')}
        if event['event'] != 'attribute' or event.get('status') != 0 or event.get('truncated'):
            return
        raw = bytes.fromhex(event.get('raw', ''))
        if len(raw) > 96:
            raise ValueError('Oversized attribute')
        cluster, attr = event.get('cluster'), event.get('attribute')
        ep['attributes'][f'{cluster:04x}:{attr:04x}'] = {
            'raw': raw.hex(), 'type': event.get('type'), 'received_at': received_at or utc_now(),
            'uptime_ms': event.get('uptime_ms'), 'report': bool(event.get('report')),
        }
        if cluster == 0 and attr in (4, 5) and event.get('type') == 0x42:
            device['manufacturer' if attr == 4 else 'model'] = zcl_string(raw)

    def report(self):
        result = json.loads(json.dumps(self.devices))
        complete = 0
        for device in result.values():
            found = False
            for ep in device['endpoints'].values():
                ep['measurements'] = {}
                for key, attr in ep['attributes'].items():
                    raw = bytes.fromhex(attr['raw'])
                    value = None
                    name, unit, scale = None, None, None
                    verified = True
                    if key == '0402:0000' and attr['type'] == 0x29 and len(raw) == 2:
                        encoded = int.from_bytes(raw, 'little', signed=True)
                        if encoded != -32768:
                            value, name, unit, scale = encoded / 100, 'temperature', '°C', 100
                            verified = (device['model'] == 'TS0201'
                                        or (device['model'], device['manufacturer']) == ('TH01', 'Zbeacon'))
                    elif key == '0405:0000' and attr['type'] == 0x21 and len(raw) == 2:
                        encoded = int.from_bytes(raw, 'little')
                        scale = HUMIDITY_DIVISORS.get((device['model'], device['manufacturer']))
                        if encoded != 0xffff and scale:
                            value, name, unit = encoded / scale, 'humidity', '%'
                            if not 0 <= value <= 100:
                                value = None
                    elif key == '0001:0020' and attr['type'] == 0x20 and len(raw) == 1 and raw[0] != 0xff:
                        value, name, unit, scale = raw[0] / 10, 'battery_voltage', 'V', 10
                    elif key == '0001:0021' and attr['type'] == 0x20 and len(raw) == 1 and raw[0] <= 200:
                        value, name, unit, scale = raw[0] / 2, 'battery_reported', '%', 2
                    if value is not None:
                        ep['measurements'][name] = dict(attr, value=value, unit=unit, divisor=scale,
                                                       conversion_verified=verified)
                measurements = ep['measurements']
                if (device['manufacturer'] and device['model'] and 'temperature' in measurements
                        and measurements['temperature']['conversion_verified'] and 'humidity' in measurements):
                    found = True
            device['complete'] = found
            complete += int(found)
        return {'schema': 1, 'complete_devices': complete, 'event_drops': self.event_drops,
                'job_drops': self.job_drops, 'devices': list(result.values())}


def report_exit_status(report, expected_devices):
    if report['complete_devices'] < expected_devices:
        print('Incomplete: raw evidence was saved; do not treat unverified values as a successful reading.', file=sys.stderr)
        return 2
    if report['event_drops'] or report['job_drops']:
        print('Queue overflow detected; evidence is incomplete.', file=sys.stderr)
        return 3
    return 0


def decode_events(source, output, expected_devices=1):
    """Reinterpret saved events without opening USB or inventing receive times."""
    evidence = Evidence()
    with source.open() as events:
        for number, line in enumerate(events, 1):
            event = json.loads(line)
            if not isinstance(event, dict) or not isinstance(event.get('received_at'), str) or not event['received_at']:
                raise ValueError(f'Missing original received_at on line {number}')
            evidence.accept(event, event['received_at'])
    report = evidence.report()
    report.update(source_events=str(source.resolve()), replayed_at=utc_now())
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
    return report_exit_status(report, expected_devices)


def capture(port, output, duration, expected_devices=1, settle_seconds=30):
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    evidence = Evidence()
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    previous = termios.tcgetattr(fd)
    settings = list(previous)
    settings[0] = settings[1] = settings[3] = 0
    settings[2] = termios.CS8 | termios.CLOCAL | termios.CREAD
    settings[4] = settings[5] = termios.B115200
    settings[6] = list(previous[6])
    settings[6][termios.VMIN] = 0
    settings[6][termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, settings)
    start, last_status = time.monotonic(), 0
    joined, ready, buffer = False, False, b''
    stop_after = None
    try:
        with (output / 'serial.log').open('wb') as serial_log, (output / 'events.jsonl').open('w') as events:
            while time.monotonic() - start < duration:
                now = time.monotonic()
                if not ready and now - last_status >= 2:
                    os.write(fd, b'status\n')
                    last_status = now
                if ready and not joined:
                    os.write(fd, b'join\n')
                    joined = True
                    print('READY: Joining is open for 180 seconds. Put ONE TH03 into pairing mode now.', flush=True)
                if not ready and now - start > 60:
                    raise RuntimeError('CoordinatorNotReady: check serial.log. If USB was connected with the boot '
                                       'button held, unplug it, wait 5 seconds and reconnect WITHOUT pressing the '
                                       'button; retry capture without reflashing.')
                if select.select([fd], [], [], 1)[0]:
                    chunk = os.read(fd, 4096)
                    if not chunk:
                        continue
                    serial_log.write(chunk)
                    serial_log.flush()
                    buffer += chunk
                    if len(buffer) > 65536:
                        raise RuntimeError('OversizedSerialLine')
                    while b'\n' in buffer:
                        line, buffer = buffer.split(b'\n', 1)
                        try:
                            event = json.loads(line)
                            if not isinstance(event, dict) or event.get('v') != 1:
                                continue
                            event['received_at'] = utc_now()
                            evidence.accept(event, event['received_at'])
                        except (ValueError, TypeError, UnicodeError):
                            continue  # SDK boot output remains available in serial.log.
                        events.write(json.dumps(event, ensure_ascii=False) + '\n')
                        events.flush()
                        if event.get('event') == 'ready' or (event.get('event') == 'status' and event.get('ready')):
                            ready = True
                        if event.get('event') in ('announce', 'descriptor', 'attribute', 'custom', 'bind_result'):
                            print(json.dumps(event, ensure_ascii=False), flush=True)
                    report = evidence.report()
                    if report['complete_devices'] >= expected_devices and stop_after is None:
                        # Capture subsequent reports too; individual timestamps stay separate.
                        stop_after = now + settle_seconds
                        os.write(fd, b'close\n')
                    if stop_after and now >= stop_after:
                        break
    finally:
        try:
            os.write(fd, b'close\n')
            termios.tcdrain(fd)
        finally:
            termios.tcsetattr(fd, termios.TCSANOW, previous)
            os.close(fd)
            report = evidence.report()
            (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
    return report_exit_status(report, expected_devices) if ready else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--port')
    source.add_argument('--events', type=Path, help='Reprocess an existing events.jsonl without USB access')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--duration', type=int, default=300)
    parser.add_argument('--expected-devices', type=int, default=1)
    args = parser.parse_args()
    if not 60 <= args.duration <= 3600 or not 1 <= args.expected_devices <= 20:
        parser.error('duration must be 60..3600; expected-devices must be 1..20')
    try:
        if args.events:
            return decode_events(args.events, args.output, args.expected_devices)
        return capture(args.port, args.output, args.duration, args.expected_devices)
    except (OSError, RuntimeError, ValueError) as error:
        print(f'Capture failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
