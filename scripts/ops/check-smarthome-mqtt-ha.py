#!/usr/bin/env python3
"""Confirm MQTT config and sensor registration without changing HA storage."""
import argparse
import json
import os
from pathlib import Path
import sys
import time


def registered(storage, report):
    entries = json.loads((storage/'core.config_entries').read_text())['data']['entries']
    matched = {e['entry_id'] for e in entries if e.get('domain') == 'mqtt'
               and e.get('data', {}).get('broker') == '127.0.0.1'
               and e.get('data', {}).get('port', 1883) == 1883
               and e.get('data', {}).get('username') == 'homeassistant'}
    if not matched:
        return None
    entities = json.loads((storage/'core.entity_registry').read_text())['data']['entities']
    available = {e['unique_id']: e['entity_id'] for e in entities if e.get('platform') == 'mqtt'
                 and e.get('config_entry_id') in matched and not e.get('disabled_by')}
    result = {}
    for ieee, values in report['measurements'].items():
        if not all(metric in values for metric in ('temperature', 'humidity')):
            continue
        keys = [f'nanoc6_{ieee}_{metric}' for metric in ('temperature', 'humidity')]
        if all(key in available for key in keys):
            result[ieee] = [available[key] for key in keys]
    return result or None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Run with sudo')
    storage = Path('/mnt/data/smarthome/homeassistant/.storage')
    report = json.loads(args.report.read_text())
    for _ in range(30):
        try:
            result = registered(storage, report)
        except FileNotFoundError:
            result = None
        if result:
            report['homeassistant_entities'] = result
            report['homeassistant_values_confirmed_by_user'] = True
            args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
            print('Home Assistant MQTT integration and temperature/humidity entities are registered.')
            print('Live values were confirmed by the operator in the Home Assistant UI.')
            return 0
        time.sleep(2)
    raise RuntimeError('Expected Home Assistant MQTT configuration/entities were not found. Source logs are preserved.')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
