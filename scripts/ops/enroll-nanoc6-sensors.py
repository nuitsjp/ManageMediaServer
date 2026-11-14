#!/usr/bin/env python3
"""Interactively enroll sensors using the existing USB coordinator and MQTT/TLS."""
import argparse
import csv
import importlib
import io
import json
import os
from pathlib import Path
import re
import signal
import tempfile
import threading
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from smarthome_mqtt import Observation, connect, private_json

Serial = importlib.import_module('provision-nanoc6-gateway').Serial
ha_registered = importlib.import_module('check-smarthome-mqtt-ha').registered
METRICS = ('temperature', 'humidity', 'battery', 'voltage')
METRIC_LABELS = dict(zip(METRICS, ('温度', '湿度', '電池残量', '電圧')))
MAX_AGES = dict(temperature=10800, humidity=10800, battery=172800, voltage=172800)
DROP_KEYS = ('event_drops', 'job_drops', 'gateway_drops', 'device_overflow')
FINGERPRINTS = {('Zbeacon', 'TH01'), ('_TZ3000_itnrsufe', 'TS0201'),
                ('_TZ3000_bguser20', 'TS0201'), ('_TZ3000_xr3htd96', 'TS0201')}
IEEE = re.compile(r'[0-9a-f]{16}')


def valid_ieee(value):
    return isinstance(value, str) and bool(IEEE.fullmatch(value)) and value != '0' * 16


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def live_values(values, since):
    now = time.time()
    return {kind: value for kind, value in values.items()
            if value['received_at'] >= max(since-2, now-MAX_AGES[kind])}


def atomic_text(path, text):
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def label(value):
    value = value.strip()
    if not value or len(value) > 80 or not value.isprintable():
        raise ValueError('設置場所は空白のみを除く80文字以内で入力してください。')
    return value


def csv_text(data):
    out = io.StringIO(newline='')
    writer = csv.writer(out)
    writer.writerow(['追加番号', '設置場所', 'IEEE', '状態', 'メーカー', 'モデル',
                     *[f'{kind} 値' for kind in METRICS],
                     *[f'{kind} 受信時刻(JST)' for kind in METRICS], 'HAデバイス画面'])
    for entry in data['entries']:
        values = entry.get('measurements', {})
        stamps = [datetime.fromtimestamp(values[k]['received_at'], ZoneInfo('Asia/Tokyo')).isoformat()
                  if k in values else '' for k in METRICS]
        writer.writerow([entry['slot'], entry['location'], entry.get('ieee') or '', entry['state'],
                         entry.get('identity', {}).get('manufacturer', ''), entry.get('identity', {}).get('model', ''),
                         *[values.get(k, {}).get('value', '') for k in METRICS], *stamps,
                         entry.get('ha_device_url', '')])
    return out.getvalue()


class Session:
    def __init__(self, path, count, baseline):
        self.path = path
        if path.exists() or path.is_symlink():
            self.data = private_json(path)
            if not isinstance(self.data, dict) or self.data.get('schema') != 1 or self.data.get('count') != count:
                raise ValueError('既存の進捗ファイルと追加台数が一致しません。上書きせず中止します。')
        else:
            self.data = dict(schema=1, count=count, baseline=sorted(set(baseline)), created_at=utc_now(),
                             completed=False, unassigned=[],
                             entries=[dict(slot=i+1, location='', ieee=None, state='pending', attempts=0)
                                      for i in range(count)])
        self.validate()
        self.save()

    def validate(self):
        data = self.data
        if (not isinstance(data.get('baseline'), list) or not isinstance(data.get('entries'), list)
                or not isinstance(data.get('unassigned'), list) or any(not valid_ieee(i) for i in data['baseline'])
                or len(set(data['baseline'])) != len(data['baseline']) or len(data.get('entries', [])) != data['count']):
            raise ValueError('進捗ファイルの機器一覧が不正です。')
        claimed, labels = set(data['baseline']), set()
        for number, entry in enumerate(data['entries'], 1):
            if (not isinstance(entry, dict) or entry.get('slot') != number
                    or entry.get('state') not in ('pending', 'joined', 'deferred', 'verified')
                    or not isinstance(entry.get('location'), str) or type(entry.get('attempts')) is not int
                    or entry['attempts'] < 0):
                raise ValueError('進捗ファイルの登録状態が不正です。')
            if entry.get('ieee'):
                if not valid_ieee(entry['ieee']) or entry['ieee'] in claimed:
                    raise ValueError('既存機器または別の登録枠への重複割り当てがあります。')
                claimed.add(entry['ieee'])
            if entry.get('location'):
                checked = label(entry['location']).casefold()
                if checked in labels:
                    raise ValueError('設置場所の識別名が重複しています。')
                labels.add(checked)
            if entry['state'] == 'verified' and (not entry.get('ieee') or not entry.get('identity_confirmed')):
                raise ValueError('確認済み機器に必要な記録がありません。')
        if any(not valid_ieee(i) or i in claimed for i in data.get('unassigned', [])):
            raise ValueError('未割当機器の記録が不正です。')
        if data.get('completed') and any(e['state'] != 'verified' for e in data['entries']):
            raise ValueError('未完了の機器を完了済みにはできません。')

    def save(self):
        self.data['updated_at'] = utc_now()
        self.validate()
        atomic_text(self.path, json.dumps(self.data, ensure_ascii=False, indent=2) + '\n')
        atomic_text(self.path.with_suffix('.csv'), csv_text(self.data))

    def claimed(self):
        return {e['ieee'] for e in self.data['entries'] if e.get('ieee')}

    def location(self, entry, value):
        value = label(value)
        if any(e is not entry and e['location'].casefold() == value.casefold() for e in self.data['entries']):
            raise ValueError('同じ識別名があります。末尾に番号などを付けて区別してください。')
        entry['location'] = value
        self.save()

    def claim(self, entry, ieee):
        if not valid_ieee(ieee) or ieee in self.data['baseline']:
            raise ValueError('既存の機器は追加機器に割り当てられません。')
        if any(e is not entry and e.get('ieee') == ieee for e in self.data['entries']):
            raise ValueError('この機器は別の登録枠に割り当て済みです。')
        if entry.get('ieee') and entry['ieee'] != ieee:
            raise ValueError('登録途中のIEEEアドレスは自動で変更しません。')
        entry.update(ieee=ieee, state='joined')
        self.data['unassigned'] = [i for i in self.data['unassigned'] if i != ieee]
        self.save()  # Preserve the association before waiting for measurements or operator input.

    def quarantine(self, addresses):
        excluded = set(self.data['baseline']) | self.claimed()
        self.data['unassigned'] = sorted(set(self.data['unassigned']) | (set(addresses)-excluded))
        self.save()

    def verified(self, entry, evidence):
        if entry['state'] != 'joined' or not entry.get('ieee'):
            raise ValueError('IEEEアドレスを記録してから確認を完了してください。')
        entry.update(evidence, state='verified', identity_confirmed=True, verified_at=utc_now())
        self.save()

    def finish(self):
        if any(e['state'] != 'verified' for e in self.data['entries']) or self.data['unassigned']:
            raise ValueError('未確認・未割当の機器があります。進捗を保存して終了します。')
        self.data.update(completed=True, homeassistant_values_confirmed_by_user=True, completed_at=utc_now())
        self.save()


def ha_inventory(storage):
    entries = json.loads((storage/'core.entity_registry').read_text())['data']['entities']
    result = set()
    for entry in entries:
        if entry.get('platform') != 'mqtt':
            continue
        match = re.fullmatch(r'nanoc6_([0-9a-f]{16})_(temperature|humidity|battery|voltage)', entry.get('unique_id', ''))
        if match:
            result.add(match[1])
    return result


class EnrollmentObservation(Observation):
    def __init__(self, started=None):
        super().__init__(started)
        self.identities = {}
        self.announcements = []
        self.addresses = {}
        self.descriptors = {}
        self.drop_baseline = None
        self.drop_deltas = {}
        self.telemetry_at = 0
        self.permit_sequence = 0
        self.permit_seconds = None
        self.gateway_status = None

    def _accept(self, topic, payload, retained=False):
        if topic == 'smarthome/nanoc6/gateway/telemetry':
            data = json.loads(payload)
            if retained or data.get('firmware') != 'nanoc6-wifi-gateway-0.2':
                raise RuntimeError('登録には確認済みのNano C6 v0.2が必要です。')
            if any(type(data.get(key)) is not int or data[key] < 0 for key in DROP_KEYS):
                raise ValueError('ゲートウェイ診断情報が不正です。')
            if self.telemetry and data.get('uptime_ms', 0) < self.telemetry.get('uptime_ms', 0):
                if self.telemetry['uptime_ms'] - data['uptime_ms'] < 0x80000000:
                    raise RuntimeError('登録中にゲートウェイが再起動しました。進捗を保存して再開してください。')
            if self.drop_baseline is None:
                self.drop_baseline = {key: data[key] for key in DROP_KEYS}
            self.drop_deltas = {key: data[key]-self.drop_baseline[key] for key in DROP_KEYS}
            if any(value != 0 for value in self.drop_deltas.values()):
                raise RuntimeError('登録中にキュー欠落または機器上限超過を検知しました。')
            self.telemetry = data
            self.telemetry_at = time.monotonic()
            return
        super()._accept(topic, payload, retained)
        if topic.startswith('homeassistant/sensor/nanoc6/'):
            data = json.loads(payload)
            match = re.fullmatch(r'smarthome/nanoc6/([0-9a-f]{16})/(temperature|humidity|battery|voltage)/state', data.get('state_topic', ''))
            if match and (match[1], match[2]) in self.discovery:
                device = data.get('device', {})
                self.identities[match[1]] = dict(manufacturer=device.get('manufacturer', ''), model=device.get('model', ''))

    def serial_event(self, event, received_at=None):
        received_at = time.time() if received_at is None else received_at
        with self.lock:
            if event.get('event') == 'permit_join':
                self.permit_sequence += 1
                self.permit_seconds = event.get('seconds')
                return
            if event.get('event') == 'gateway_status':
                self.gateway_status = event
                return
            ieee = event.get('ieee')
            if not valid_ieee(ieee) or event.get('status') != 0:
                return
            if type(event.get('short')) is int and 0 < event['short'] < 0xfff8:
                self.addresses[ieee] = (event['short'], received_at)
            if event.get('event') == 'announce':
                self.announcements.append((ieee, received_at))
                self.announcements = self.announcements[-256:]
            elif event.get('event') == 'descriptor' and event.get('endpoint') == 1 and not event.get('truncated'):
                self.descriptors[ieee] = {key: event.get(key) for key in ('profile', 'device', 'in_clusters', 'out_clusters')}
            elif (event.get('event') == 'attribute' and event.get('cluster') == 0 and event.get('attribute') in (4, 5)
                  and event.get('type') == 0x42 and not event.get('truncated')):
                raw = bytes.fromhex(event.get('raw', ''))
                if raw and raw[0] != 255 and raw[0] <= len(raw)-1:
                    value = raw[1:1+raw[0]].decode('utf-8')
                    self.identities.setdefault(ieee, {})['manufacturer' if event['attribute'] == 4 else 'model'] = value

    def candidates(self, since, excluded):
        with self.lock:
            return {ieee for ieee, timestamp in self.announcements if timestamp >= since and ieee not in excluded}

    def inventory(self):
        with self.lock:
            return {i for i in set(self.identities) | set((self.telemetry or {}).get('power_configuration', {}))
                    if valid_ieee(i)}

    def evidence(self, ieee, since, storage):
        with self.lock:
            identity = dict(self.identities.get(ieee, {}))
            if identity.get('manufacturer') and identity.get('model'):
                if (identity['manufacturer'], identity['model']) not in FINGERPRINTS:
                    raise ValueError('未対応の機種情報です: ' + json.dumps(identity, ensure_ascii=False))
            else:
                return None
            descriptor = self.descriptors.get(ieee)
            if descriptor and (descriptor['profile'] != 260 or not {1, 1026, 1029}.issubset(descriptor['in_clusters'])):
                raise ValueError('想定した温湿度・電源クラスターがありません。')
            report = super().report()
            values = live_values(report['measurements'].get(ieee, {}), since)
            configuration = (self.telemetry or {}).get('power_configuration', {}).get(ieee, {})
            if not all(kind in values and (ieee, kind) in self.discovery for kind in METRICS):
                return None
            if not configuration.get('configured') and not configuration.get('unsupported'):
                return None
            evidence = dict(identity=identity, measurements=values, power_configuration=dict(configuration),
                            descriptor=descriptor, drop_deltas=dict(self.drop_deltas))
        registered = ha_registered(storage, {'measurements': {ieee: values}}, METRICS)
        if not registered or ieee not in registered:
            return None
        evidence['homeassistant_entities'] = registered[ieee]
        registry = storage/'core.device_registry'
        if registry.exists():
            for device in json.loads(registry.read_text())['data']['devices']:
                if ['mqtt', f'nanoc6_{ieee}'] in device.get('identifiers', []):
                    evidence['ha_device_url'] = 'http://192.168.0.23:8123/config/devices/device/' + device['id']
                    break
        return evidence

    def progress(self, ieee, since, storage):
        """Explain missing evidence without treating HA registration as live delivery."""
        with self.lock:
            identity = dict(self.identities.get(ieee, {}))
            values = self.report()['measurements'].get(ieee, {})
            received = list(live_values(values, since))
            discovery = [kind for kind in METRICS if (ieee, kind) in self.discovery]
            configuration = dict((self.telemetry or {}).get('power_configuration', {}).get(ieee, {}))
            address = self.addresses.get(ieee)
        # Placeholder keys select registry entries only; they are never saved as measurements.
        entities = ha_registered(storage, {'measurements': {ieee: {kind: None for kind in METRICS}}}, METRICS)
        missing = [METRIC_LABELS[kind]+'の新規受信' for kind in METRICS if kind not in received]
        if not identity.get('manufacturer') or not identity.get('model'):
            missing.append('機種情報')
        if len(discovery) != len(METRICS):
            missing.append('MQTT Discovery')
        if not configuration.get('configured') and not configuration.get('unsupported'):
            missing.append('電池の定期報告設定')
        if not entities:
            missing.append('Home Assistantの4項目登録')
        return dict(checked_at=utc_now(), missing=missing, identity=identity,
                    received=received, measurements=values, discovery=discovery,
                    power_configuration=configuration, homeassistant_registered=bool(entities),
                    live_usb_address=dict(short=address[0], observed_at=address[1]) if address else None)


class Collector:
    def __init__(self, client, serial, observation):
        self.client, self.serial, self.observation = client, serial, observation
        self.error = None
        self.serial_error = None
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self.stopped.is_set():
            if self.error is None:
                try:
                    message = self.client.receive(0.1)
                    if message:
                        self.observation.accept(*message)
                except (OSError, ValueError, RuntimeError) as error:
                    self.error = error
            try:
                event = self.serial.receive(0.1)
                if event:
                    self.observation.serial_event(event)
            except (OSError, ValueError) as error:
                self.serial_error = error
                self.stopped.wait(0.2)

    def check(self):
        if self.serial_error:
            raise RuntimeError('USB制御との通信が失われました。') from self.serial_error
        if self.error:
            raise RuntimeError(str(self.error)) from self.error
        with self.observation.lock:
            if not self.observation.online:
                raise RuntimeError('MQTT上でNano C6がofflineです。')
            if self.observation.telemetry_at and time.monotonic()-self.observation.telemetry_at > 100:
                raise RuntimeError('ゲートウェイの診断情報が更新されていません。')

    def permit(self, seconds):
        with self.observation.lock:
            previous = self.observation.permit_sequence
        self.serial.send('join' if seconds else 'close')
        end = time.monotonic()+10
        while time.monotonic() < end:
            with self.observation.lock:
                if self.observation.permit_sequence > previous and self.observation.permit_seconds == seconds:
                    return
            if self.serial_error:
                break
            time.sleep(0.05)
        raise RuntimeError('参加受付の開閉をUSBで確認できませんでした。受付は最長180秒で自動終了します。')

    def shutdown(self):
        self.stopped.set()
        self.thread.join(3)
        self.serial.close()
        self.client.close()


class Enroller:
    def __init__(self, session, collector, storage, prompt=input, pairing_seconds=180, verify_seconds=600):
        self.session, self.collector, self.storage, self.prompt = session, collector, storage, prompt
        self.observation = collector.observation
        self.pairing_seconds, self.verify_seconds = pairing_seconds, verify_seconds
        self.join_closed = False

    def close(self):
        self.join_closed = False
        self.collector.permit(0)
        self.join_closed = True

    def reconcile(self):
        known = self.observation.inventory() | self.observation.candidates(0, set())
        self.session.quarantine(known)

    def choose_unassigned(self, entry):
        unassigned = self.session.data['unassigned']
        if not unassigned:
            return False
        print(f"「{entry['location']}」に置く機器を選びます。以下はZigbee参加済みで、設置場所が未割当の機器です。")
        print('今回ペアリングした実機との対応が分かる場合だけ、そのIEEEをコピーして入力してください。分からなければqで中断できます。')
        for ieee in unassigned:
            print('  ' + ieee)
        chosen = self.prompt('識別済みIEEE / q=中断: ').strip().lower()
        if chosen == 'q':
            raise KeyboardInterrupt
        if chosen not in unassigned:
            raise ValueError('未割当一覧のIEEEを指定してください。推測で関連付けないでください。')
        self.session.claim(entry, chosen)
        return True

    def pair(self, entry):
        self.close()
        self.collector.check()
        self.reconcile()
        if self.choose_unassigned(entry):
            print('設置場所との対応を保存しました。この機器の新しい受信を確認します。', flush=True)
            return time.time()
        answer = self.prompt('この1台だけを手元に用意。Enter=180秒の参加受付を開始 / q=中断: ').strip().lower()
        if answer == 'q':
            raise KeyboardInterrupt
        if answer:
            raise ValueError('Enterまたはqを入力してください。')
        self.collector.check()
        started = time.time()
        self.join_closed = False
        self.collector.permit(180)
        print('READY: 今の1台だけを、説明書に従ってペアリングモードにしてください。', flush=True)
        excluded = set(self.session.data['baseline']) | self.session.claimed()
        candidates = set()
        try:
            end = time.monotonic()+self.pairing_seconds
            while time.monotonic() < end:
                self.collector.check()
                candidates = self.observation.candidates(started, excluded)
                if candidates:
                    break
                time.sleep(0.1)
        finally:
            self.close()
        if not candidates:
            raise TimeoutError('新しい機器を検出できませんでした。参加受付を閉じました。')
        # Drain announcements already in flight after closing permit-join.
        time.sleep(2)
        candidates = self.observation.candidates(started, excluded)
        self.session.quarantine(candidates)
        if len(candidates) != 1:
            raise ValueError('複数台を検出したため、自動で設置場所へ割り当てず未割当として保存しました。')
        self.session.claim(entry, next(iter(candidates)))
        return started

    def verify(self, entry, since):
        print(f"IEEE {entry['ieee']} を確認中: 機種・温度・湿度・電池残量・電圧・HA登録", flush=True)
        print('最大10分待ちます。進捗は10秒ごとに表示します。Ctrl+Cで保存して中断できます。', flush=True)
        self.collector.serial.send('refresh-battery')  # Firmware bounds rate and retries, including sleeping devices.
        # The collector runs during prompts too. A live non-retained value received
        # before the operator typed this IEEE must not require another battery report.
        reception_since = self.observation.started
        started = time.monotonic()
        end, last_interview, last_progress = started+self.verify_seconds, None, None
        while time.monotonic() < end:
            self.collector.check()
            unexpected = self.observation.candidates(since, set(self.session.data['baseline']) | self.session.claimed())
            if unexpected:
                self.session.quarantine(unexpected)
                raise ValueError('別の新規機器を検出しました。参加受付を閉じたまま確認を中断します。')
            evidence = self.observation.evidence(entry['ieee'], reception_since, self.storage)
            if evidence:
                entry.pop('waiting', None)
                return evidence
            with self.observation.lock:
                address = self.observation.addresses.get(entry['ieee'])
            # A live USB mapping observed while the user was typing is usable too.
            # Never reuse a NWK address from a previous process or a saved session.
            live_address = address and address[1] >= max(self.observation.started-2, time.time()-300)
            if live_address and (last_interview is None or time.monotonic()-last_interview >= 300):
                self.collector.serial.send(f'interview {address[0]:04x}')
                last_interview = time.monotonic()
                print('USBで確認できた通信先へ、機種情報と測定値の再読出しを要求しました。', flush=True)
            if last_progress is None or time.monotonic()-last_progress >= 10:
                progress = self.observation.progress(entry['ieee'], reception_since, self.storage)
                elapsed = int(time.monotonic()-started)
                progress.update(elapsed_seconds=elapsed, remaining_seconds=max(0, int(end-time.monotonic())))
                entry['waiting'] = progress
                self.session.save()
                received = '・'.join(METRIC_LABELS[kind] for kind in progress['received']) or 'なし'
                pending = '、'.join(progress['missing']) or '最終照合'
                print(f"確認中 {elapsed}秒 / 残り約{progress['remaining_seconds']}秒：今回受信済み={received}。待機項目={pending}", flush=True)
                if not live_address:
                    print('この実行中のUSB受信で通信先を確認できていません。受信を待っています。', flush=True)
                last_progress = time.monotonic()
            time.sleep(0.25)
        pending = '、'.join(entry.get('waiting', {}).get('missing', []))
        raise TimeoutError('受信確認が時間内に揃いませんでした。未確認: '+pending+'。IEEEとの対応は保存済みです。')

    def run(self):
        self.close()
        try:
            print(f"既存 {len(self.session.data['baseline'])} 台を保護し、追加 {self.session.data['count']} 台を順次登録します。")
            print('未登録の機器は1台ずつ電源を入れ、ペアリングしてください。登録済みの機器はそのまま使えます。')
            print('設置場所は対応表に保存します。HAの名称・エリアは最後のデバイスリンクから設定できます。')
            for entry in self.session.data['entries']:
                if entry['state'] == 'verified':
                    print(f"確認済みを再利用: {entry['slot']} {entry['location']} {entry['ieee']}")
                    continue
                print(f"\n=== 追加 {entry['slot']}/{self.session.data['count']} ===")
                while not entry['location']:
                    answer = self.prompt('設置場所名（例: 寝室01）/ q=保存して中断: ')
                    if answer.strip().lower() == 'q':
                        raise KeyboardInterrupt
                    try:
                        self.session.location(entry, answer)
                    except ValueError as error:
                        print(error)
                print('登録先: ' + entry['location'], flush=True)
                while entry['state'] != 'verified':
                    entry['attempts'] += 1
                    self.session.save()
                    try:
                        since = time.time()
                        if not entry.get('ieee'):
                            since = self.pair(entry)
                        else:
                            print('登録途中の機器を再確認します。再ペアリングは自動で行いません。')
                            print('スリープ中は受信まで待ちます。必要なら説明書に従って短押しで起こしてください。')
                            self.session.claim(entry, entry['ieee'])
                        evidence = self.verify(entry, since)
                        print(json.dumps(dict(ieee=entry['ieee'], location=entry['location'],
                                              identity=evidence['identity'], measurements=evidence['measurements']),
                                         ensure_ascii=False, indent=2))
                        if evidence.get('ha_device_url'):
                            print('HAデバイス: ' + evidence['ha_device_url'])
                        if evidence['power_configuration'].get('unsupported'):
                            print('定期報告設定は非対応。補助読出しで取得できています。')
                        answer = self.prompt('この実機と設置場所の対応を確認できたらEnter / q=保存して中断: ').strip().lower()
                        if answer == 'q':
                            raise KeyboardInterrupt
                        if answer:
                            raise ValueError('確認にはEnterを入力してください。')
                        self.collector.check()
                        self.reconcile()
                        self.session.verified(entry, evidence)
                        print('保存しました。次の機器へ進みます。', flush=True)
                    except (TimeoutError, ValueError) as error:
                        self.close()
                        entry['last_error'] = str(error)
                        self.session.save()
                        print(str(error), flush=True)
                        answer = self.prompt('r=同じ機器を再試行 / s=保留して次へ / q=保存して中断: ').strip().lower()
                        if answer == 'r':
                            continue
                        if answer == 's':
                            entry['state'] = 'deferred'
                            self.session.save()
                            break
                        raise KeyboardInterrupt
            self.reconcile()
            remaining = [e for e in self.session.data['entries'] if e['state'] != 'verified']
            if remaining or self.session.data['unassigned']:
                print('未完了の機器があります。同じスクリプトで再開できます。')
                return 2
            self.close()
            print('\n追加機器の一覧:')
            for entry in self.session.data['entries']:
                print(f"{entry['slot']}: {entry['location']}  {entry['ieee']}  {entry.get('ha_device_url', '')}")
            answer = self.prompt('HAで追加機器の表示を確認できたらEnter / q=保存して後で確認: ').strip().lower()
            if answer:
                raise KeyboardInterrupt
            self.collector.check()
            self.reconcile()
            self.session.finish()
            print(f"追加 {self.session.data['count']} 台を確認しました。既存を含め合計 {len(self.session.data['baseline'])+len(self.session.claimed())} 台です。")
            return 0
        finally:
            try:
                self.close()
            except (OSError, RuntimeError) as error:
                self.join_closed = False
                self.session.data['close_error'] = str(error)
            self.session.data['join_closed'] = self.join_closed
            self.session.save()
            if not self.join_closed:
                raise RuntimeError('参加受付の終了を確認できませんでした。最大180秒で自動終了します。')


def run(args):
    config = private_json(args.credentials)
    observation = EnrollmentObservation()
    client = connect(config, args.ca)
    serial = None
    collector = None
    session = None
    try:
        client.subscribe('smarthome/nanoc6/#')
        client.subscribe('homeassistant/sensor/nanoc6/#')
        serial = Serial()
        collector = Collector(client, serial, observation)
        collector.thread.start()
        collector.permit(0)
        serial.send('gateway-status')
        last_status = time.monotonic()
        end = time.monotonic()+90
        while time.monotonic() < end:
            if collector.error or collector.serial_error:
                collector.check()
            with observation.lock:
                status = observation.gateway_status or {}
                if (observation.telemetry and observation.online and status.get('firmware') == 'nanoc6-wifi-gateway-0.2'
                        and all(status.get(k) for k in ('wifi', 'mqtt', 'clock'))):
                    break
            if time.monotonic()-last_status >= 5:
                serial.send('gateway-status')
                last_status = time.monotonic()
            time.sleep(0.1)
        else:
            raise RuntimeError('Nano C6の接続状態または新しいtelemetryを確認できません。')
        collector.check()
        inventory = ha_inventory(args.storage) | observation.inventory()
        session = Session(args.session, args.count, inventory)
        session.quarantine(inventory - set(session.data['baseline']) - session.claimed())
        if len(session.data['baseline']) + args.count > 20:
            raise ValueError('既存＋追加機器が直下20台の設定を超えます。')
        enroller = Enroller(session, collector, args.storage)
        if session.data['completed']:
            if session.data['unassigned']:
                raise ValueError('完了後に別の新規機器を検出しました。既存の対応表を保持して中止します。')
            session.data['join_closed'] = True
            session.save()
            print('この登録セッションは完了済みです。対応表を再利用できます。')
            return 0
        return enroller.run()
    except KeyboardInterrupt:
        print('\n進捗を保存して中断します。同じスクリプトで再開できます。', flush=True)
        return 2
    except (OSError, ValueError, RuntimeError) as error:
        if session:
            session.data['last_error'] = str(error)
            session.save()
        raise
    finally:
        if collector:
            try:
                collector.permit(0)
            except (OSError, RuntimeError):
                if session:
                    session.data['join_closed'] = False
                    session.save()
                raise RuntimeError('参加受付の終了を確認できませんでした。最大180秒で自動終了します。')
            finally:
                collector.shutdown()
        else:
            if serial:
                serial.close()
            client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--count', type=int, default=9)
    parser.add_argument('--session', type=Path, default=Path('/mnt/data/smarthome/nanoc6/enrollment/session.json'))
    parser.add_argument('--storage', type=Path, default=Path('/mnt/data/smarthome/homeassistant/.storage'))
    parser.add_argument('--credentials', type=Path, default=Path('/etc/manage-smarthome/mqtt-clients.json'))
    parser.add_argument('--ca', type=Path, default=Path('/mnt/data/smarthome/mosquitto/config/ca.crt'))
    args = parser.parse_args()
    if os.geteuid() != 0 or not os.isatty(0) or not 1 <= args.count <= 19:
        parser.error('sudoの対話端末で、追加台数1..19を指定してください。')
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    return run(args)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(f'ERROR: {error}', flush=True)
        raise SystemExit(1)
