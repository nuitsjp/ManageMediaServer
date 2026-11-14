#!/usr/bin/env python3
"""Check published names and diagnostic entities without changing Home Assistant."""
import argparse
import importlib
import json
from pathlib import Path
import time

from smarthome_mqtt import connect, private_json

registered = importlib.import_module('check-smarthome-mqtt-ha').registered
KINDS = ('temperature', 'humidity', 'battery', 'voltage', 'last_seen', 'reception')


def validate_config(topic, payload, expected):
    data = json.loads(payload)
    for number, ieee in expected:
        for kind in KINDS:
            unique = f'nanoc6_{ieee}_{kind}'
            if topic != f'homeassistant/sensor/nanoc6/{unique}/config':
                continue
            device = data.get('device', {})
            return ((ieee, kind) if data.get('unique_id') == unique
                    and data.get('state_topic') == f'smarthome/nanoc6/{ieee}/{kind}/state'
                    and device.get('identifiers') == [f'nanoc6_{ieee}']
                    and device.get('name') == f'温湿度計{number:02}' else None)
    return None


def registry_names(storage, expected):
    try:
        devices = json.loads((storage/'core.device_registry').read_text())['data']['devices']
    except FileNotFoundError:
        return False
    for number, ieee in expected:
        matching = [device for device in devices if ['mqtt', f'nanoc6_{ieee}'] in device.get('identifiers', [])]
        if len(matching) != 1:
            return False
        device = matching[0]
        desired = f'温湿度計{number:02}'
        custom = device.get('name_by_user')
        if custom and custom != desired:
            raise RuntimeError(f'HAの手動名「{custom}」が優先されています。対象デバイスの名前を「{desired}」へ変更してください。')
        if (custom or device.get('name')) != desired:
            return False
    return True


def run(mapping, credentials, ca, storage, duration):
    expected = [(int(k), value['ieee']) for k, value in sorted(mapping['devices'].items())]
    if not expected:
        raise ValueError('番号の対応表が空です。')
    required = {(ieee, kind) for _, ieee in expected for kind in KINDS}
    seen = set()
    client = connect(private_json(credentials), ca)
    try:
        client.subscribe('homeassistant/sensor/nanoc6/#')
        deadline = time.monotonic()+duration
        while time.monotonic() < deadline:
            message = client.receive(1)
            if message:
                topic, payload, _ = message
                found = validate_config(topic, payload, expected)
                if found:
                    seen.add(found)
            if seen == required:
                report = {'measurements': {ieee: {kind: None for kind in KINDS} for _, ieee in expected}}
                found_entities = registered(storage, report, KINDS)
                if (found_entities and set(found_entities) == {ieee for _, ieee in expected}
                        and registry_names(storage, expected)):
                    print('全機器のMQTT名前・6種類のDiscoveryとHAエンティティ登録を確認しました。', flush=True)
                    return
        missing = sorted(required-seen)
        detail = repr(missing) if missing else 'Home Assistantのエンティティまたはデバイス名が未反映'
        raise RuntimeError('MQTT DiscoveryまたはHome Assistantの登録が不足しています: '+detail)
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mapping', type=Path, required=True)
    parser.add_argument('--credentials', type=Path, default=Path('/etc/manage-smarthome/mqtt-clients.json'))
    parser.add_argument('--ca', type=Path, default=Path('/mnt/data/smarthome/mosquitto/config/ca.crt'))
    parser.add_argument('--storage', type=Path, default=Path('/mnt/data/smarthome/homeassistant/.storage'))
    parser.add_argument('--duration', type=int, default=120)
    args = parser.parse_args()
    run(private_json(args.mapping), args.credentials, args.ca, args.storage, args.duration)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        raise SystemExit(f'ERROR: {error}')
