#!/usr/bin/env python3
"""Observe new battery/voltage readings over MQTT; never provision or reset a sensor."""
import argparse
import json
from pathlib import Path
import sys
import time

from smarthome_mqtt import Observation, connect, private_json


class PowerObservation(Observation):
    def __init__(self, targets, started=None, expected_firmware='nanoc6-wifi-gateway-0.2'):
        super().__init__(started)
        self.targets = set(targets)
        self.expected_firmware = expected_firmware
        self.boot_started = None

    def _accept(self, topic, payload, retained=False):
        if topic == 'smarthome/nanoc6/gateway/telemetry':
            data = json.loads(payload)
            if retained or data.get('firmware') != self.expected_firmware:
                return  # The observer starts BEFORE flashing; old firmware cannot prove the fix.
            uptime = data.get('uptime_ms')
            if type(uptime) is not int or uptime < 0:
                raise ValueError('Invalid firmware uptime')
            self.boot_started = time.time() - uptime / 1000
        super()._accept(topic, payload, retained)

    def report(self):
        with self.lock:
            result = super().report()
            threshold = max(self.started-2, self.boot_started-2) if self.boot_started is not None else float('inf')
            result['measurements'] = {
                ieee: {kind: value for kind, value in values.items() if value['received_at'] >= threshold}
                for ieee, values in result['measurements'].items() if ieee in self.targets
            }
            configuration = (result.get('telemetry') or {}).get('power_configuration', {})
            complete = []
            for ieee in self.targets:
                values = result['measurements'].get(ieee, {})
                configured = configuration.get(ieee, {})
                if all(kind in values and (ieee, kind) in self.discovery for kind in ('temperature', 'humidity', 'battery', 'voltage')):
                    if configured.get('configured') or configured.get('unsupported'):
                        complete.append(ieee)
            result.update(complete_devices=len(complete), targets=sorted(self.targets),
                          firmware_verified=self.boot_started is not None, expected_firmware=self.expected_firmware)
            return result


def run(args):
    config = private_json(args.credentials)
    observation = PowerObservation(args.ieee)
    client = connect(config, args.ca)
    try:
        client.subscribe('smarthome/nanoc6/#')
        client.subscribe('homeassistant/sensor/nanoc6/#')
        args.ready_file.write_text('MQTT observer started before firmware update.\n')
        end, last_saved = time.monotonic() + args.duration, 0
        while time.monotonic() < end:
            message = client.receive()
            if message:
                observation.accept(*message)
            report = observation.report()
            if time.monotonic() - last_saved > 5:
                args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
                last_saved = time.monotonic()
            if report['online'] and report['firmware_verified'] and report['complete_devices'] == len(observation.targets):
                for ieee in report['targets']:
                    values = report['measurements'][ieee]
                    print(f"{ieee}: battery={values['battery']['value']}% voltage={values['voltage']['value']}V "
                          f"temperature={values['temperature']['value']}C humidity={values['humidity']['value']}%", flush=True)
                print('New battery/voltage measurements and HA discovery received over verified MQTT/TLS.', flush=True)
                return 0
        print('Incomplete: new battery/voltage readings or reporting acknowledgement are still missing.', file=sys.stderr)
        return 2
    finally:
        client.close()
        args.output.write_text(json.dumps(observation.report(), ensure_ascii=False, indent=2)+'\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials', type=Path, default=Path('/etc/manage-smarthome/mqtt-clients.json'))
    parser.add_argument('--ca', type=Path, default=Path('/mnt/data/smarthome/mosquitto/config/ca.crt'))
    parser.add_argument('--ieee', action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ready-file', type=Path, required=True)
    parser.add_argument('--duration', type=int, default=1800)
    args = parser.parse_args()
    if not 60 <= args.duration <= 3600 or not 1 <= len(set(args.ieee)) <= 20:
        parser.error('Use duration 60..3600 and 1..20 sensor IEEE addresses')
    if any(len(ieee) != 16 or any(c not in '0123456789abcdef' for c in ieee) for ieee in args.ieee):
        parser.error('Use 16 lowercase hex digits for an IEEE address')
    return run(args)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
