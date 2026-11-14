import contextlib
import importlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts/ops'))
ENROLL = importlib.import_module('enroll-nanoc6-sensors')
EXISTING = 'a4c1385a39992474'
ADDED = [f'a4c13800000000{i:02x}' for i in range(1, 10)]


def telemetry(ids, uptime=10000, drops=0):
    return dict(firmware='nanoc6-wifi-gateway-0.2', uptime_ms=uptime,
                event_drops=drops, job_drops=0, gateway_drops=0, device_overflow=0,
                power_configuration={i: dict(configured=True, unsupported=False) for i in ids})


def sensor(observer, ieee, stamp=None):
    stamp = time.time() if stamp is None else stamp
    for kind, value in zip(ENROLL.METRICS, (23.4, 46.2, 100, 2.9)):
        topic = f'smarthome/nanoc6/{ieee}/{kind}/state'
        config = dict(unique_id=f'nanoc6_{ieee}_{kind}', state_topic=topic,
                      device=dict(identifiers=[f'nanoc6_{ieee}'], manufacturer='Zbeacon', model='TH01'))
        observer.accept(f'homeassistant/sensor/nanoc6/{ieee}_{kind}/config', json.dumps(config).encode(), True)
        observer.accept(topic, json.dumps(dict(value=value, received_at=stamp)).encode())


class FakeSerial:
    def __init__(self):
        self.commands = []

    def send(self, command):
        self.commands.append(command)


class FakeCollector:
    def __init__(self, observer, batches=()):
        self.observation, self.batches = observer, iter(batches)
        self.serial, self.permits = FakeSerial(), []

    def permit(self, seconds):
        self.permits.append(seconds)
        if seconds:
            for ieee in next(self.batches):
                self.observation.serial_event(dict(event='announce', ieee=ieee, short=1234, status=0))
                sensor(self.observation, ieee)
            ids = self.observation.inventory()
            self.observation.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry(ids)).encode())

    def check(self):
        pass


class EnrollmentTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.session_path = self.path/'session.json'
        self.storage = self.path/'storage'
        self.storage.mkdir()
        entries = [dict(entry_id='mqtt1', domain='mqtt',
                        data=dict(broker='127.0.0.1', port=1883, username='homeassistant'))]
        entities = [dict(platform='mqtt', config_entry_id='mqtt1', disabled_by=None,
                         unique_id=f'nanoc6_{i}_{kind}', entity_id=f'sensor.{i}_{kind}')
                    for i in [EXISTING, *ADDED] for kind in ENROLL.METRICS]
        (self.storage/'core.config_entries').write_text(json.dumps(dict(data=dict(entries=entries))))
        (self.storage/'core.entity_registry').write_text(json.dumps(dict(data=dict(entities=entities))))

    def observer(self):
        observer = ENROLL.EnrollmentObservation()
        observer.accept('smarthome/nanoc6/gateway/availability', b'online', True)
        observer.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry([EXISTING])).encode())
        sensor(observer, EXISTING)
        return observer

    def test_existing_and_duplicate_ieee_cannot_be_assigned(self):
        session = ENROLL.Session(self.session_path, 9, [EXISTING])
        a, b = session.data['entries'][:2]
        with self.assertRaises(ValueError):
            session.claim(a, EXISTING)
        session.claim(a, ADDED[0])
        with self.assertRaises(ValueError):
            session.claim(b, ADDED[0])
        with self.assertRaises(ValueError):
            session.claim(a, ADDED[1])
        self.assertEqual(session.data['baseline'], [EXISTING])

    def test_progress_and_csv_are_private_and_survive_interruption(self):
        session = ENROLL.Session(self.session_path, 9, [EXISTING])
        entry = session.data['entries'][0]
        session.location(entry, '寝室,"窓側"')
        session.claim(entry, ADDED[0])
        resumed = ENROLL.Session(self.session_path, 9, [EXISTING, ADDED[0]])
        self.assertEqual(resumed.data['baseline'], [EXISTING])
        self.assertEqual(resumed.data['entries'][0]['ieee'], ADDED[0])
        self.assertEqual(self.session_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.session_path.with_suffix('.csv').stat().st_mode & 0o777, 0o600)
        self.assertIn('"寝室,""窓側"""', self.session_path.with_suffix('.csv').read_text())
        with self.assertRaises(ValueError):
            ENROLL.Session(self.session_path, 8, [EXISTING])

    def test_corrupt_duplicate_progress_and_symlink_are_rejected(self):
        session = ENROLL.Session(self.session_path, 9, [EXISTING])
        session.data['entries'][0]['ieee'] = EXISTING
        with self.assertRaises(ValueError):
            session.save()
        link = self.path/'linked.json'
        link.symlink_to(self.session_path)
        with self.assertRaises(OSError):
            ENROLL.Session(link, 9, [EXISTING])

    def test_duplicate_locations_and_empty_names_are_rejected(self):
        session = ENROLL.Session(self.session_path, 9, [EXISTING])
        session.location(session.data['entries'][0], '寝室01')
        for value in ('寝室01', '  ', 'a\nb'):
            with self.assertRaises(ValueError):
                session.location(session.data['entries'][1], value)

    def test_two_simultaneous_joins_are_quarantined_and_closed(self):
        session = ENROLL.Session(self.session_path, 9, [EXISTING])
        collector = FakeCollector(self.observer(), [ADDED[:2]])
        enroller = ENROLL.Enroller(session, collector, self.storage, prompt=lambda _: '')
        with patch.object(ENROLL.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(ValueError):
                enroller.pair(session.data['entries'][0])
        self.assertIsNone(session.data['entries'][0]['ieee'])
        self.assertEqual(session.data['unassigned'], ADDED[:2])
        self.assertEqual(collector.permits[-1], 0)

    def test_no_join_timeout_and_prompt_interrupt_close_admission(self):
        session = ENROLL.Session(self.session_path, 1, [EXISTING])
        collector = FakeCollector(self.observer(), [[]])
        enroller = ENROLL.Enroller(session, collector, self.storage, prompt=lambda _: '', pairing_seconds=0)
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(TimeoutError):
                enroller.pair(session.data['entries'][0])
        self.assertEqual(collector.permits[-1], 0)
        enroller.prompt = lambda _: (_ for _ in ()).throw(KeyboardInterrupt())
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(KeyboardInterrupt):
                enroller.run()
        self.assertTrue(json.loads(self.session_path.read_text())['join_closed'])

    def test_nine_sequential_sensors_protect_existing_and_complete_with_four_metrics(self):
        before = {file.name: file.read_bytes() for file in self.storage.iterdir()}
        session = ENROLL.Session(self.session_path, 9, [EXISTING])
        collector = FakeCollector(self.observer(), [[i] for i in ADDED])
        answers = iter([answer for i in range(9) for answer in (f'設置場所{i+1:02}', '', '')] + [''])
        enroller = ENROLL.Enroller(session, collector, self.storage, prompt=lambda _: next(answers))
        with patch.object(ENROLL.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(enroller.run(), 0)
        self.assertEqual(collector.permits.count(180), 9)
        self.assertEqual(collector.permits[-1], 0)
        saved = json.loads(self.session_path.read_text())
        self.assertTrue(saved['completed'])
        self.assertEqual(saved['baseline'], [EXISTING])
        self.assertEqual({e['ieee'] for e in saved['entries']}, set(ADDED))
        for entry in saved['entries']:
            self.assertEqual(set(entry['measurements']), set(ENROLL.METRICS))
            self.assertEqual(len(entry['homeassistant_entities']), 4)
        self.assertIn('+09:00', self.session_path.with_suffix('.csv').read_text())
        self.assertEqual(before, {file.name: file.read_bytes() for file in self.storage.iterdir()})

    def test_failed_close_is_not_saved_as_confirmed(self):
        session = ENROLL.Session(self.session_path, 1, [EXISTING])
        collector = FakeCollector(self.observer())
        enroller = ENROLL.Enroller(session, collector, self.storage)
        enroller.close()
        def fail_close(_):
            raise RuntimeError('USB disconnected')
        collector.permit = fail_close
        with self.assertRaises(RuntimeError):
            enroller.close()
        self.assertFalse(enroller.join_closed)

    def test_deferred_join_resumes_same_ieee_without_opening_join(self):
        session = ENROLL.Session(self.session_path, 1, [EXISTING])
        answers = iter(['寝室', '', 's'])
        collector = FakeCollector(self.observer(), [[ADDED[0]]])
        first = ENROLL.Enroller(session, collector, self.storage, prompt=lambda _: next(answers), verify_seconds=0)
        with patch.object(ENROLL.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(first.run(), 2)
        self.assertEqual(session.data['entries'][0]['state'], 'deferred')
        resumed = ENROLL.Session(self.session_path, 1, [])
        second = FakeCollector(self.observer())
        sensor(second.observation, ADDED[0])
        second.observation.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry([EXISTING, ADDED[0]])).encode())
        enroller = ENROLL.Enroller(resumed, second, self.storage, prompt=lambda _: '')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(enroller.run(), 0)
        self.assertNotIn(180, second.permits)
        self.assertIn('refresh-battery', second.serial.commands)
        self.assertEqual(resumed.data['entries'][0]['ieee'], ADDED[0])

    def test_old_measurements_or_missing_ha_battery_cannot_complete(self):
        observer = self.observer()
        now = time.time()
        observer.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry(ADDED)).encode())
        sensor(observer, ADDED[0], now-120)
        self.assertIsNone(observer.evidence(ADDED[0], now, self.storage))
        sensor(observer, ADDED[0], now)
        self.assertIsNotNone(observer.evidence(ADDED[0], now, self.storage))
        registry = self.storage/'core.entity_registry'
        data = json.loads(registry.read_text())
        for e in data['data']['entities']:
            if e['unique_id'] == f'nanoc6_{ADDED[0]}_battery':
                e['disabled_by'] = 'user'
        registry.write_text(json.dumps(data))
        self.assertIsNone(observer.evidence(ADDED[0], now, self.storage))

    def test_waiting_progress_separates_live_reception_discovery_and_ha_registration(self):
        observer = self.observer()
        now = time.time()
        sensor(observer, ADDED[0], now)
        observer.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry(ADDED)).encode())
        observer.measurements[ADDED[0]].pop('battery')
        progress = observer.progress(ADDED[0], now, self.storage)
        self.assertEqual(progress['missing'], ['電池残量の新規受信'])
        self.assertTrue(progress['homeassistant_registered'])
        self.assertNotIn('battery', progress['received'])
        self.assertNotIn('battery', progress['measurements'])

    def test_retry_reads_using_usb_address_seen_before_the_operator_answered(self):
        observer = self.observer()
        observer.started = time.time()-120
        sensor(observer, ADDED[0], observer.started-10)
        observer.serial_event(dict(event='attribute', ieee=ADDED[0], short=0x1234, status=0), time.time()-30)
        collector = FakeCollector(observer)
        session = ENROLL.Session(self.session_path, 1, [EXISTING])
        entry = session.data['entries'][0]
        session.claim(entry, ADDED[0])
        enroller = ENROLL.Enroller(session, collector, self.storage, verify_seconds=0.01)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(TimeoutError):
            enroller.verify(entry, time.time())
        self.assertIn('interview 1234', collector.serial.commands)
        self.assertIn('待機項目=', output.getvalue())
        self.assertIn('電池残量の新規受信', output.getvalue())
        saved = json.loads(self.session_path.read_text())['entries'][0]
        self.assertIn('waiting', saved)
        self.assertEqual(saved['waiting']['received'], [])

    def test_live_values_received_before_ieee_input_do_not_require_a_second_battery_report(self):
        observer = self.observer()
        observer.started = time.time()-120
        sensor(observer, ADDED[0], time.time()-30)
        observer.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry(ADDED)).encode())
        collector = FakeCollector(observer)
        session = ENROLL.Session(self.session_path, 1, [EXISTING])
        entry = session.data['entries'][0]
        session.claim(entry, ADDED[0])
        enroller = ENROLL.Enroller(session, collector, self.storage, verify_seconds=0.01)
        with contextlib.redirect_stdout(io.StringIO()):
            evidence = enroller.verify(entry, time.time())
        self.assertEqual(set(evidence['measurements']), set(ENROLL.METRICS))
        self.assertLess(evidence['measurements']['battery']['received_at'], time.time()-20)

    def test_values_from_a_long_prompt_do_not_outlive_homeassistant_expiry(self):
        observer = self.observer()
        observer.started = time.time()-20000
        sensor(observer, ADDED[0], time.time()-11000)
        observer.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry(ADDED)).encode())
        self.assertIsNone(observer.evidence(ADDED[0], observer.started, self.storage))
        progress = observer.progress(ADDED[0], observer.started, self.storage)
        self.assertEqual(progress['received'], ['battery', 'voltage'])

    def test_retry_never_uses_a_usb_address_from_before_this_process(self):
        observer = self.observer()
        observer.serial_event(dict(event='attribute', ieee=ADDED[0], short=0x1234, status=0), observer.started-10)
        collector = FakeCollector(observer)
        session = ENROLL.Session(self.session_path, 1, [EXISTING])
        entry = session.data['entries'][0]
        session.claim(entry, ADDED[0])
        enroller = ENROLL.Enroller(session, collector, self.storage, verify_seconds=0.01)
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(TimeoutError):
            enroller.verify(entry, time.time())
        self.assertNotIn('interview 1234', collector.serial.commands)

    def test_unknown_fingerprint_and_new_drops_block_verification(self):
        observer = self.observer()
        sensor(observer, ADDED[0])
        observer.identities[ADDED[0]]['manufacturer'] = 'unknown'
        with self.assertRaises(ValueError):
            observer.evidence(ADDED[0], time.time(), self.storage)
        with self.assertRaises(RuntimeError):
            observer.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry([], drops=1)).encode())

    def test_historic_drop_counter_is_baselined_but_reboot_is_detected(self):
        observer = ENROLL.EnrollmentObservation()
        observer.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry([], drops=3)).encode())
        observer.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry([], uptime=11000, drops=3)).encode())
        self.assertFalse(any(observer.drop_deltas.values()))
        with self.assertRaises(RuntimeError):
            observer.accept('smarthome/nanoc6/gateway/telemetry', json.dumps(telemetry([], uptime=100, drops=3)).encode())

    def test_closed_admission_needs_a_new_matching_usb_ack(self):
        master, slave = os.openpty()
        serial = ENROLL.Serial(os.ttyname(slave))
        class Client:
            def receive(self, timeout):
                time.sleep(timeout)
            def close(self):
                pass
        observer = self.observer()
        collector = ENROLL.Collector(Client(), serial, observer)
        collector.thread.start()
        import threading
        commands = []
        def board():
            for seconds in (180, 0):
                command = b''
                while not command.endswith(b'\n'):
                    command += os.read(master, 32)
                commands.append(command.decode().strip())
                os.write(master, json.dumps(dict(v=1, event='permit_join', seconds=seconds)).encode()+b'\n')
        thread = threading.Thread(target=board, daemon=True)
        thread.start()
        try:
            collector.permit(180)
            collector.permit(0)
            thread.join(2)
            self.assertEqual(commands, ['join', 'close'])
        finally:
            collector.shutdown()
            os.close(master)
            os.close(slave)


if __name__ == '__main__':
    unittest.main()
