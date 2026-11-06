"""Decode actual ZCL representations and exercise serial capture with a pseudo tty."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('probe', ROOT / 'scripts/ops/capture-nanoc6-usb.py')
PROBE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PROBE)


def attribute(ieee, cluster, attr, dtype, raw, **kwargs):
    return dict(v=1, event='attribute', ieee=ieee, short=0x1234, endpoint=1, status=0,
                cluster=cluster, attribute=attr, type=dtype, raw=raw.hex(), **kwargs)


def identity(ieee, manufacturer='_TZ3000_itnrsufe', model='TS0201'):
    return [attribute(ieee, 0, attr, 0x42, bytes([len(value)]) + value.encode())
            for attr, value in ((4, manufacturer), (5, model))]


class ZclEvidenceTests(unittest.TestCase):
    def test_observed_zbeacon_th01_reads_and_automatic_reports(self):
        # Raw values observed on the retail TH03; use a synthetic IEEE address.
        ieee = 'a4c1380000000001'
        evidence = PROBE.Evidence()
        for event in identity(ieee, 'Zbeacon', 'TH01'):
            evidence.accept(event)
        for cluster, attr, dtype, raw in ((0x0402, 0, 0x29, '940a'),
                                          (0x0405, 0, 0x21, 'cb10'),
                                          (1, 32, 0x20, '1e'), (1, 33, 0x20, 'c8')):
            evidence.accept(attribute(ieee, cluster, attr, dtype, bytes.fromhex(raw)))
        report = evidence.report()
        self.assertEqual(report['complete_devices'], 1)
        metrics = report['devices'][0]['endpoints']['1']['measurements']
        self.assertEqual(metrics['temperature']['value'], 27.08)
        self.assertTrue(metrics['temperature']['conversion_verified'])
        self.assertEqual(metrics['humidity']['value'], 42.99)
        self.assertEqual(metrics['battery_voltage']['value'], 3.0)
        self.assertEqual(metrics['battery_reported']['value'], 100)
        evidence.accept(attribute(ieee, 0x0402, 0, 0x29, bytes.fromhex('a00a'), report=True),
                        '2026-11-06T23:04:22.681678+00:00')
        evidence.accept(attribute(ieee, 0x0405, 0, 0x21, bytes.fromhex('0f11'), report=True),
                        '2026-11-06T23:04:22.751141+00:00')
        metrics = evidence.report()['devices'][0]['endpoints']['1']['measurements']
        self.assertEqual(metrics['temperature']['value'], 27.20)
        self.assertEqual(metrics['humidity']['value'], 43.67)
        self.assertTrue(metrics['temperature']['report'])
        self.assertTrue(metrics['humidity']['report'])
        # The model name alone must not select Zbeacon's humidity conversion.
        for event in identity(ieee, 'unknown', 'TH01'):
            evidence.accept(event)
        self.assertEqual(evidence.report()['complete_devices'], 0)
        self.assertFalse(evidence.report()['devices'][0]['endpoints']['1']['measurements']['temperature']['conversion_verified'])

    def test_offline_replay_cli_preserves_original_time_and_rejects_missing_time(self):
        ieee = 'a4c1380000000001'
        events = identity(ieee, 'Zbeacon', 'TH01') + [
            attribute(ieee, 0x0402, 0, 0x29, bytes.fromhex('a00a'), report=True),
            attribute(ieee, 0x0405, 0, 0x21, bytes.fromhex('0f11'), report=True)]
        for event in events:
            event['received_at'] = '2026-11-06T23:04:22+00:00'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / 'events.jsonl', root / 'decoded'
            source.write_text(''.join(json.dumps(event) + '\n' for event in events))
            command = [sys.executable, str(ROOT / 'scripts/ops/capture-nanoc6-usb.py'),
                       '--events', str(source), '--output', str(output)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((output / 'report.json').read_text())
            self.assertEqual(report['complete_devices'], 1)
            self.assertEqual(report['source_events'], str(source))
            self.assertEqual(report['devices'][0]['endpoints']['1']['measurements']['humidity']['received_at'],
                             events[-1]['received_at'])
            self.assertEqual(len(source.read_text().splitlines()), 4)
            events[-1]['event_drops'] = 1
            source.write_text(''.join(json.dumps(event) + '\n' for event in events))
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 3)
            del events[-1]['received_at']
            source.write_text(''.join(json.dumps(event) + '\n' for event in events))
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Missing original received_at', result.stderr)

    def test_ten_sensors_with_identical_short_addresses_never_overwrite_each_other(self):
        evidence = PROBE.Evidence()
        for number in range(10):
            ieee = f'{number+1:016x}'
            for event in identity(ieee):
                evidence.accept(event)
            evidence.accept(attribute(ieee, 0x0402, 0, 0x29, (2100+number).to_bytes(2, 'little', signed=True)))
            evidence.accept(attribute(ieee, 0x0405, 0, 0x21, (450+number).to_bytes(2, 'little')))
        report = evidence.report()
        self.assertEqual(report['complete_devices'], 10)
        self.assertEqual(len(report['devices']), 10)
        for number, device in enumerate(report['devices']):
            metrics = device['endpoints']['1']['measurements']
            self.assertEqual(metrics['temperature']['value'], (2100+number)/100)
            self.assertEqual(metrics['humidity']['value'], (450+number)/10)

    def test_known_standard_and_vendor_humidity_scales_are_selected_by_fingerprint(self):
        for manufacturer, encoded in (('_TZ3000_bguser20', 4520), ('_TZ3000_itnrsufe', 452)):
            evidence = PROBE.Evidence()
            for event in identity('a4c1380000000001', manufacturer):
                evidence.accept(event)
            evidence.accept(attribute('a4c1380000000001', 0x0405, 0, 0x21, encoded.to_bytes(2, 'little')))
            self.assertEqual(evidence.report()['devices'][0]['endpoints']['1']['measurements']['humidity']['value'], 45.2)

    def test_unknown_humidity_is_retained_raw_without_guessing_scale(self):
        evidence = PROBE.Evidence()
        for event in identity('a4c1380000000001', '_TZ3000_unknown'):
            evidence.accept(event)
        evidence.accept(attribute('a4c1380000000001', 0x0405, 0, 0x21, b'\xc4\x01'))
        ep = evidence.report()['devices'][0]['endpoints']['1']
        self.assertNotIn('humidity', ep['measurements'])
        self.assertEqual(ep['attributes']['0405:0000']['raw'], 'c401')
        self.assertEqual(evidence.report()['complete_devices'], 0)

    def test_signed_temperature_invalid_sentinels_and_missing_values(self):
        evidence = PROBE.Evidence()
        ieee = 'a4c1380000000001'
        for event in identity(ieee):
            evidence.accept(event)
        evidence.accept(attribute(ieee, 0x0402, 0, 0x29, (-550).to_bytes(2, 'little', signed=True)))
        self.assertEqual(evidence.report()['devices'][0]['endpoints']['1']['measurements']['temperature']['value'], -5.5)
        evidence.accept(attribute(ieee, 0x0402, 0, 0x29, b'\x00\x80'))
        evidence.accept(attribute(ieee, 0x0405, 0, 0x21, b'\xff\xff'))
        self.assertEqual(evidence.report()['devices'][0]['endpoints']['1']['measurements'], {})
        evidence.accept(attribute(ieee, 0x0402, 0, 0x29, b''))
        self.assertEqual(evidence.report()['devices'][0]['endpoints']['1']['measurements'], {})

    def test_metrics_keep_separate_receive_times_even_when_values_do_not_change(self):
        evidence = PROBE.Evidence()
        ieee = 'a4c1380000000001'
        for event in identity(ieee):
            evidence.accept(event)
        event = attribute(ieee, 0x0402, 0, 0x29, b'\x34\x08')
        evidence.accept(event, 'first')
        evidence.accept(attribute(ieee, 0x0405, 0, 0x21, b'\xc4\x01'), 'humidity-only')
        self.assertEqual(evidence.report()['devices'][0]['endpoints']['1']['measurements']['temperature']['received_at'], 'first')
        evidence.accept(event, 'same-value-new-report')
        self.assertEqual(evidence.report()['devices'][0]['endpoints']['1']['measurements']['temperature']['received_at'], 'same-value-new-report')

    def test_invalid_identity_truncated_data_and_failed_reads_are_not_measurements(self):
        evidence = PROBE.Evidence()
        evidence.accept(attribute('0000000000000000', 0x0402, 0, 0x29, b'\x01\x00'))
        self.assertEqual(evidence.report()['devices'], [])
        event = attribute('a4c1380000000001', 0x0402, 0, 0x29, b'\x01\x00', truncated=True)
        evidence.accept(event)
        event['truncated'] = False
        event['status'] = 0x86
        evidence.accept(event)
        self.assertEqual(evidence.report()['devices'][0]['endpoints']['1']['measurements'], {})

    def test_serial_handshake_raw_capture_and_report_without_hardware(self):
        master, slave = os.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        commands = []
        stop = threading.Event()

        def device():
            buffer = b''
            while not stop.is_set():
                if not select.select([master], [], [], 0.05)[0]:
                    continue
                buffer += os.read(master, 4096)
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    command = line.strip().decode(errors='replace')
                    commands.append(command)
                    if command == 'status':
                        os.write(master, b'SDK boot output\n{"v":1,"event":"status","ready":true}\n')
                    elif command == 'join':
                        ieee = 'a4c1380000000001'
                        events = identity(ieee) + [attribute(ieee, 0x0402, 0, 0x29, b'\x34\x08'),
                                                   attribute(ieee, 0x0405, 0, 0x21, b'\xc4\x01')]
                        os.write(master, b''.join((json.dumps(event)+'\n').encode() for event in events))

        thread = threading.Thread(target=device, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory, redirect_stdout(io.StringIO()):
                output = Path(directory)
                result = PROBE.capture(os.ttyname(slave), output, 3, settle_seconds=0)
                self.assertEqual(result, 0)
                self.assertEqual(json.loads((output / 'report.json').read_text())['complete_devices'], 1)
                self.assertIn('SDK boot output', (output / 'serial.log').read_text())
                time.sleep(0.05)
                self.assertIn('join', commands)
                self.assertIn('close', commands)
        finally:
            stop.set()
            thread.join(2)


if __name__ == '__main__':
    unittest.main()
