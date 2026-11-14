import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts/ops'))
NUMBERS = importlib.import_module('assign-nanoc6-numbers')
CHECK = importlib.import_module('check-nanoc6-numbers')


class FakeSerial:
    def __init__(self, firmware='nanoc6-wifi-gateway-0.3', reject=None):
        self.firmware, self.reject = firmware, reject
        self.events, self.sent, self.saved = [], [], {}

    def send(self, command):
        self.sent.append(command)
        if command == 'gateway-status':
            self.events.append(dict(event='gateway_status', firmware=self.firmware))
        else:
            request = json.loads(command)
            if request['command'] == 'get-number':
                self.events.append(dict(event='number_value', ieee=request['ieee'],
                                        number=self.saved.get(request['ieee'], 0), healthy=True))
            else:
                if request['number'] != self.reject:
                    self.saved[request['ieee']] = request['number']
                self.events.append(dict(event='number_result', ieee=request['ieee'], number=request['number'],
                                        accepted=request['number'] != self.reject))

    def receive(self, timeout):
        return self.events.pop(0) if self.events else None


class NumberAssignmentTests(unittest.TestCase):
    def test_ha_manual_name_cannot_silently_override_the_requested_name(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ieee = 'a4c138e9b48af1fc'
            device = dict(identifiers=[['mqtt', f'nanoc6_{ieee}']], name='温湿度計01', name_by_user=None)
            path = root/'core.device_registry'
            path.write_text(json.dumps(dict(data=dict(devices=[device]))))
            self.assertTrue(CHECK.registry_names(root, [(1, ieee)]))
            device['name_by_user'] = '作業部屋'
            path.write_text(json.dumps(dict(data=dict(devices=[device]))))
            with self.assertRaises(RuntimeError): CHECK.registry_names(root, [(1, ieee)])
            device['name_by_user'] = '温湿度計01'
            path.write_text(json.dumps(dict(data=dict(devices=[device]))))
            self.assertTrue(CHECK.registry_names(root, [(1, ieee)]))

    def test_discovery_requires_the_correct_name_identity_and_state_topic(self):
        ieee = 'a4c138e9b48af1fc'
        unique = f'nanoc6_{ieee}_last_seen'
        topic = f'homeassistant/sensor/nanoc6/{unique}/config'
        data = dict(unique_id=unique, state_topic=f'smarthome/nanoc6/{ieee}/last_seen/state',
                    device=dict(identifiers=[f'nanoc6_{ieee}'], name='温湿度計01'))
        self.assertEqual(CHECK.validate_config(topic, json.dumps(data), [(1, ieee)]), (ieee, 'last_seen'))
        data['device']['name'] = '温湿度計02'
        self.assertIsNone(CHECK.validate_config(topic, json.dumps(data), [(1, ieee)]))
        data['device']['name'] = '温湿度計01'
        data['state_topic'] = 'smarthome/nanoc6/other/last_seen/state'
        self.assertIsNone(CHECK.validate_config(topic, json.dumps(data), [(1, ieee)]))

    def test_only_private_unique_valid_mappings_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'numbers.json'
            data = dict(schema=1, devices={'01': dict(ieee='a4c138e9b48af1fc'),
                                          '02': dict(ieee='a4c1385a39992474')})
            path.write_text(json.dumps(data)); path.chmod(0o600)
            self.assertEqual(NUMBERS.assignments(path), [(1, 'a4c138e9b48af1fc'), (2, 'a4c1385a39992474')])
            data['devices']['02']['ieee'] = data['devices']['01']['ieee']
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError): NUMBERS.assignments(path)
            path.chmod(0o644)
            with self.assertRaises(ValueError): NUMBERS.assignments(path)

    def test_old_firmware_and_conflicting_numbers_are_not_silently_accepted(self):
        mapping = [(1, 'a4c138e9b48af1fc'), (2, 'a4c1385a39992474')]
        old = FakeSerial(firmware='nanoc6-wifi-gateway-0.2')
        with self.assertRaises(RuntimeError): NUMBERS.apply(old, mapping)
        self.assertEqual(old.sent, ['gateway-status'])
        rejected = FakeSerial(reject=2)
        with self.assertRaises(RuntimeError): NUMBERS.apply(rejected, mapping)
        self.assertEqual(len(rejected.sent), 4)
        successful = FakeSerial()
        NUMBERS.apply(successful, mapping)
        self.assertEqual(len(successful.sent), 5)
        NUMBERS.apply(successful, mapping, verify_only=True)
        self.assertEqual(len(successful.sent), 8)
        empty = FakeSerial()
        with self.assertRaises(RuntimeError): NUMBERS.apply(empty, mapping, verify_only=True)


if __name__ == '__main__':
    unittest.main()
