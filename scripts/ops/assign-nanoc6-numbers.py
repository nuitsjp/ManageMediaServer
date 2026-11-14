#!/usr/bin/env python3
"""Send already-identified sensor numbers to a Nano C6 over its USB port."""
import argparse
import importlib
import json
from pathlib import Path
import re
import time

from smarthome_mqtt import private_json

Serial = importlib.import_module('provision-nanoc6-gateway').Serial


def assignments(path):
    data = private_json(path)
    if not isinstance(data, dict) or data.get('schema') != 1 or not isinstance(data.get('devices'), dict):
        raise ValueError('対応表の形式が不正です。')
    result, seen = [], set()
    for key, item in sorted(data['devices'].items()):
        if not re.fullmatch(r'0[1-9]|10', key) or not isinstance(item, dict):
            raise ValueError('番号は01〜10で指定してください。')
        ieee = item.get('ieee')
        if not isinstance(ieee, str) or not re.fullmatch(r'[0-9a-f]{16}', ieee) or ieee == '0'*16 or ieee in seen:
            raise ValueError('機器IDが不正か、複数番号に重複しています。')
        seen.add(ieee)
        result.append((int(key), ieee))
    if not result:
        raise ValueError('対応表に機器がありません。')
    return result


def wait_event(serial, predicate, timeout):
    end = time.monotonic()+timeout
    while time.monotonic() < end:
        event = serial.receive(min(1, max(0, end-time.monotonic())))
        if event and predicate(event):
            return event
        if event and event.get('event') in ('invalid_number_request', 'number_queue_full'):
            raise RuntimeError('M5Stackが番号の指示を受け付けませんでした: '+event['event'])
    raise TimeoutError('M5Stackからの応答を確認できません。')


def apply(serial, mapping, verify_only=False):
    serial.send('gateway-status')
    status = wait_event(serial, lambda e: e.get('event') == 'gateway_status', 15)
    if status.get('firmware') != 'nanoc6-wifi-gateway-0.3':
        raise RuntimeError('番号付けに対応したv0.3の起動を確認できません。')
    for number, ieee in mapping:
        if not verify_only:
            serial.send(json.dumps(dict(command='assign-number', ieee=ieee, number=number)))
            response = wait_event(serial, lambda e: e.get('event') == 'number_result'
                                  and e.get('ieee') == ieee and e.get('number') == number, 15)
            if response.get('accepted') is not True:
                raise RuntimeError(f'温湿度計{number:02}の保存が拒否されました。既存の番号と保存状態を確認してください。')
        serial.send(json.dumps(dict(command='get-number', ieee=ieee)))
        response = wait_event(serial, lambda e: e.get('event') == 'number_value' and e.get('ieee') == ieee, 15)
        if response.get('healthy') is not True or response.get('number') != number:
            raise RuntimeError(f'温湿度計{number:02}の保存内容が一致しません。')
        print(f'温湿度計{number:02}: {ieee} をM5Stackで確認', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mapping', type=Path, required=True)
    parser.add_argument('--verify-only', action='store_true', help='保存した番号を変更せず読み取る')
    args = parser.parse_args()
    mapping = assignments(args.mapping)
    serial = Serial()
    try:
        apply(serial, mapping, args.verify_only)
    finally:
        serial.close()


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        raise SystemExit(f'ERROR: {error}')
