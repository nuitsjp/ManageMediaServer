"""Exercise deployment isolation and firewall transitions without sudo or network."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
import importlib.util
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
OPS = ROOT / 'scripts/ops'

# A stateful iptables model: the real rule-building shell functions run unchanged.
IPTABLES_MODEL = r'''
import json, os, shlex, sys
from pathlib import Path
path = Path(os.environ['RULE_STATE'])
data = json.loads(path.read_text())
tool, *args = sys.argv[1:]
chains = data[tool]
if args[:1] == ['-w']: args = args[2:]
op, chain, *rule = args
if os.environ.get('FAIL_RULE') and op == '-I' and '-s' in rule:
    raise SystemExit(2)
if op == '-N':
    if chain in chains: raise SystemExit(1)
    chains[chain] = []
elif chain not in chains:
    raise SystemExit(1)
elif op == '-S':
    print('-N ' + chain)
    for item in chains[chain]: print(shlex.join(['-A', chain, *item]))
elif op == '-C':
    if rule not in chains[chain]: raise SystemExit(1)
elif op == '-I':
    index = int(rule.pop(0)) - 1
    chains[chain].insert(index, rule)
elif op == '-D':
    if len(rule) == 1 and rule[0].isdigit(): del chains[chain][int(rule[0]) - 1]
    elif rule in chains[chain]: chains[chain].remove(rule)
    else: raise SystemExit(1)
elif op == '-F': chains[chain] = []
elif op == '-X':
    if chains[chain]: raise SystemExit(1)
    del chains[chain]
else: raise SystemExit('unsupported: ' + op)
path.write_text(json.dumps(data))
'''


class FirewallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.model = self.directory / 'iptables.py'
        self.model.write_text(IPTABLES_MODEL)
        self.state = self.directory / 'state.json'
        self.original = {
            tool: {'INPUT': [['-p', 'tcp', '--dport', '22', '-j', 'ACCEPT']],
                   'DOCKER-USER': [['-j', 'RETURN']]}
            for tool in ('iptables', 'ip6tables')
        }
        self.state.write_text(json.dumps(self.original))

    def run_rules(self, command, fail=False):
        code = f'''
source {shlex.quote(str(OPS / 'apply-smarthome-firewall.sh'))}
iptables() {{ python3 {shlex.quote(str(self.model))} iptables "$@"; }}
ip6tables() {{ python3 {shlex.quote(str(self.model))} ip6tables "$@"; }}
LAN_CIDR=192.168.0.0/24
LAN_IFACE=enp1s0
{command}
'''
        env = dict(os.environ, RULE_STATE=str(self.state))
        if fail:
            env['FAIL_RULE'] = '1'
        return subprocess.run(['bash', '-c', code], env=env, capture_output=True, text=True, timeout=15)

    def test_idempotent_apply_keeps_other_service_rules_and_blocks_ipv6(self):
        for _ in range(2):
            result = self.run_rules('apply_rules iptables; apply_rules ip6tables')
            self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.state.read_text())
        for tool, chains in state.items():
            self.assertEqual(chains['DOCKER-USER'], self.original[tool]['DOCKER-USER'])
            self.assertEqual(chains['INPUT'][1:], self.original[tool]['INPUT'])
            self.assertEqual(chains['INPUT'][0], ['-p', 'tcp', '--dport', '8123', '-j', 'MMS-SMARTHOME'])
            self.assertEqual(chains['MMS-SMARTHOME'][0], ['-i', 'lo', '-j', 'ACCEPT'])
            self.assertEqual(chains['MMS-SMARTHOME'][-1], ['-j', 'DROP'])
        self.assertEqual(len(state['ip6tables']['MMS-SMARTHOME']), 2)
        self.assertEqual(state['iptables']['MMS-SMARTHOME'][1],
                         ['-i', 'enp1s0', '-s', '192.168.0.0/24', '-j', 'ACCEPT'])

    def test_lan_change_replaces_old_allow_and_remove_restores_original(self):
        self.assertEqual(self.run_rules('apply_rules iptables; apply_rules ip6tables').returncode, 0)
        result = self.run_rules('LAN_CIDR=192.168.5.0/24; apply_rules iptables')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('192.168.0.0/24', self.state.read_text())
        result = self.run_rules('remove_rules iptables; remove_rules ip6tables; remove_rules iptables')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.state.read_text()), self.original)

    def test_failed_rule_replacement_leaves_drop_in_place(self):
        self.assertEqual(self.run_rules('apply_rules iptables').returncode, 0)
        result = self.run_rules('apply_rules iptables', fail=True)
        self.assertNotEqual(result.returncode, 0)
        chains = json.loads(self.state.read_text())['iptables']
        self.assertEqual(chains['MMS-SMARTHOME'][-1], ['-j', 'DROP'])
        self.assertEqual(chains['INPUT'][0][-1], 'MMS-SMARTHOME')


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.repo = self.directory / 'repo'
        self.prod = self.directory / 'production'
        self.systemd = self.directory / 'systemd'
        self.repo.mkdir()
        for source in ('docker/homeassistant', 'config/homeassistant', 'config/apparmor'):
            shutil.copytree(ROOT / source, self.repo / source)
        for source in ('config/env/smarthome-firewall.env.example', 'docs/スマートホーム基盤.md',
                       'scripts/ops/deploy-managed-files.sh', 'scripts/ops/install-smarthome-foundation.sh',
                       'scripts/ops/smarthome-preflight.sh', 'scripts/ops/apply-smarthome-firewall.sh',
                       'scripts/ops/check-smarthome-bluetooth.py', 'scripts/ops/repair-smarthome-bluetooth.sh',
                       'systemd/homeassistant.service', 'systemd/smarthome-firewall.service',
                       'systemd/smarthome-apparmor.service'):
            target = self.repo / source
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / source, target)
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'add', '.'], check=True)
        self.sudo_dir = self.directory / 'bin'
        self.sudo_dir.mkdir()
        sudo = self.sudo_dir / 'sudo'
        sudo.write_text('#!/bin/sh\nexec "$@"\n')
        sudo.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.sudo_dir}:{os.environ["PATH"]}',
                        PROD_ROOT=str(self.prod), SYSTEMD_ROOT=str(self.systemd),
                        BACKUP_PARENT=str(self.directory / 'backup'))

    def deploy(self, *args):
        return subprocess.run(['bash', str(self.repo / 'scripts/ops/deploy-managed-files.sh'),
                               '--smarthome-only', *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_deploy_preserves_host_secrets_and_other_services_and_backs_up(self):
        sentinels = ('docker/immich/docker-compose.yml', 'docker/homeassistant/.env',
                     'config/env/notification.env', 'AGENTS.md')
        for source in sentinels:
            target = self.prod / source
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('preserve this\n')
        old_compose = self.prod / 'docker/homeassistant/docker-compose.yml'
        old_compose.write_text('old compose\n')
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        for source in sentinels:
            self.assertEqual((self.prod / source).read_text(), 'preserve this\n')
        self.assertEqual(old_compose.read_bytes(), (ROOT / 'docker/homeassistant/docker-compose.yml').read_bytes())
        self.assertEqual((self.systemd / 'homeassistant.service').read_bytes(),
                         (ROOT / 'systemd/homeassistant.service').read_bytes())
        backups = list((self.directory / 'backup').rglob('docker-compose.yml'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'old compose\n')

    def test_dry_run_writes_nothing(self):
        result = self.deploy('--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in (self.prod, self.systemd, self.directory / 'backup'):
            self.assertFalse(path.exists())

    def test_untracked_source_is_rejected_before_deployment(self):
        subprocess.run(['git', '-C', str(self.repo), 'rm', '--cached',
                        'config/env/smarthome-firewall.env.example'], check=True, capture_output=True)
        result = self.deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.prod.exists())


class InstallerRollbackTests(unittest.TestCase):
    def test_restore_preserves_secret_data_and_continues_after_docker_failure(self):
        for docker_failure in (False, True):
            with self.subTest(docker_failure=docker_failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                backup = root / 'backup'
                data = root / 'data'
                data.mkdir()
                (data / 'secret').write_text('pairing information')
                target = root / 'installed'
                target.write_text('new')
                saved = backup / 'files' / str(target).lstrip('/')
                saved.parent.mkdir(parents=True)
                saved.write_text('old')
                new_file = root / 'new-file'
                new_file.write_text('new')
                fake_ops = root / 'repo/scripts/ops'
                fake_ops.mkdir(parents=True)
                (fake_ops / 'apply-smarthome-firewall.sh').write_text('#!/bin/bash\nexit 0\n')
                source = (OPS / 'install-smarthome-foundation.sh').read_text()
                functions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}',
                                                source, re.M | re.S)[0]
                                      for name in ('rollback_command', 'finish'))
                code = f'''
set -euo pipefail
{functions}
BACKUP={shlex.quote(str(backup))}
DATA_ROOT={shlex.quote(str(data))}
REPO_ROOT={shlex.quote(str(root / 'repo'))}
TARGETS=({shlex.quote(str(target))} {shlex.quote(str(new_file))})
STAGE=verify
CHANGED=true
BLUEZ_WAS_ACTIVE=false
BLUEZ_WAS_ENABLED=false
systemctl() {{ printf '%s\\n' "$*" >> {shlex.quote(str(root / 'systemctl.log'))}; }}
logger() {{ :; }}
docker() {{
    {'if [[ $1 == compose || $1 == ps ]]; then return 1; fi' if docker_failure else ':'}
    return 0
}}
trap finish EXIT
false
'''
                result = subprocess.run(['bash', '-c', code], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(target.read_text(), 'old')
                self.assertFalse(new_file.exists())
                report = (backup / 'result.txt').read_text()
                self.assertIn(f'rollback_failed={str(docker_failure).lower()}', report)
                preserved = data if docker_failure else backup / 'failed-data'
                self.assertEqual((preserved / 'secret').read_text(), 'pairing information')
                calls = (root / 'systemctl.log').read_text()
                self.assertIn('disable --now homeassistant.service smarthome-firewall.service', calls)
                self.assertNotIn('immich', calls)
                self.assertNotIn('jellyfin', calls)


spec = importlib.util.spec_from_file_location('bluetooth_probe', OPS / 'check-smarthome-bluetooth.py')
PROBE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PROBE)


class BluetoothProbeTests(unittest.IsolatedAsyncioTestCase):
    async def run_probe(self, adapters, denied=None, event=None):
        calls = []

        class Bus:
            def add_message_handler(self, handler):
                self.handler = handler

            def remove_message_handler(self, handler):
                self.handler = None

            async def call(self, message):
                calls.append(message.member)
                if message.member == denied:
                    return SimpleNamespace(message_type='error', error_name='org.freedesktop.DBus.Error.AccessDenied')
                if message.member == 'GetManagedObjects' and event is not None:
                    self.handler(event)
                return SimpleNamespace(message_type='return', body=[adapters])

        return await PROBE.check_bluez(Bus(), SimpleNamespace, 'error', 'signal', signal_timeout=0.02), calls

    def device_event(self):
        return SimpleNamespace(message_type='signal', interface='org.freedesktop.DBus.Properties',
                               member='PropertiesChanged', path='/org/bluez/hci0/dev_TEST',
                               body=['org.bluez.Device1', {'RSSI': -70}, []])

    def adapter(self, powered=True, scanning=True):
        return {'/org/bluez/hci0': {'org.bluez.Adapter1': {
            'Powered': SimpleNamespace(value=powered), 'Discovering': SimpleNamespace(value=scanning)}}}

    async def test_active_scan_requires_successful_bus_subscription_and_bluez_access(self):
        report, calls = await self.run_probe(self.adapter(), event=self.device_event())
        self.assertEqual(report, {'status': 'ok', 'adapters': 1, 'powered': 1, 'scanning': 1,
                                 'received_device_signals': 1})
        self.assertEqual(calls, ['AddMatch', 'GetManagedObjects'])
        self.assertNotIn('hci0', json.dumps(report))

    async def test_dbus_denial_is_not_mistaken_for_a_working_bluetooth_adapter(self):
        for member in ('AddMatch', 'GetManagedObjects'):
            with self.subTest(member=member), self.assertRaisesRegex(PROBE.ProbeError, 'AccessDenied'):
                await self.run_probe(self.adapter(), denied=member)

    async def test_missing_unpowered_or_idle_adapter_is_not_ready(self):
        for adapters, error in (({}, 'NoBlueZAdapter'), (self.adapter(False), 'AdapterNotPowered'),
                                (self.adapter(scanning=False), 'AdapterNotScanning')):
            with self.subTest(error=error), self.assertRaisesRegex(PROBE.ProbeError, error):
                await self.run_probe(adapters)

    async def test_scanning_without_received_device_signals_is_not_success(self):
        events = [None, SimpleNamespace(message_type='signal', interface='org.freedesktop.DBus.Properties',
                                       member='PropertiesChanged', path='/org/bluez/hci0',
                                       body=['org.bluez.Adapter1', {'Discovering': True}, []])]
        for event in events:
            with self.subTest(event=event), self.assertRaisesRegex(PROBE.ProbeError, 'NoLiveDeviceSignals'):
                await self.run_probe(self.adapter(), event=event)

    async def test_device_added_signal_proves_reception_without_exposing_device_path(self):
        event = SimpleNamespace(message_type='signal', interface='org.freedesktop.DBus.ObjectManager',
                                member='InterfacesAdded', path='/',
                                body=['/org/bluez/hci0/dev_TEST', {'org.bluez.Device1': {}}])
        report, _ = await self.run_probe(self.adapter(), event=event)
        self.assertEqual(report['received_device_signals'], 1)
        self.assertNotIn('dev_TEST', json.dumps(report))


class BluetoothRepairRollbackTests(unittest.TestCase):
    def test_active_oneshot_loader_is_executed_again_after_profile_changes(self):
        source = (OPS / 'repair-smarthome-bluetooth.sh').read_text()
        function = re.search(r'^load_apparmor_profile\(\) \{\n.*?^\}', source, re.M | re.S)[0]
        for was_active in ('true', 'false'):
            with self.subTest(was_active=was_active):
                # Model systemd's oneshot state: starting an active unit does not reload it.
                code = f'''
set -euo pipefail
ACTIVE={was_active}
LOADED=old
systemctl() {{
    case "$1" in
        enable) ;;
        start) if [[ $ACTIVE == false ]]; then LOADED=new; ACTIVE=true; fi ;;
        restart) LOADED=new; ACTIVE=true ;;
        is-active) [[ $ACTIVE == true ]] ;;
        *) return 2 ;;
    esac
}}
{function}
load_apparmor_profile
[[ $LOADED == new && $ACTIVE == true ]]
'''
                result = subprocess.run(['bash', '-c', code], capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_repair_restores_previous_files_but_keeps_policy_when_ha_cannot_stop(self):
        for stop_failed in (False, True):
            with self.subTest(stop_failed=stop_failed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                backup = root / 'backup'
                policy = root / 'policy'
                policy.write_text('new policy')
                saved = backup / 'files' / str(policy).lstrip('/')
                saved.parent.mkdir(parents=True)
                saved.write_text('old policy')
                new_unit = root / 'new.service'
                new_unit.write_text('new')
                source = (OPS / 'repair-smarthome-bluetooth.sh').read_text()
                function = re.search(r'^finish\(\) \{\n.*?^\}', source, re.M | re.S)[0]
                code = f'''
set -euo pipefail
{function}
BACKUP={shlex.quote(str(backup))}
AA_FILE={shlex.quote(str(policy))}
TARGETS=({shlex.quote(str(policy))} {shlex.quote(str(new_unit))})
STAGE=verify
CHANGED=true
AA_WAS_ENABLED=false
systemctl() {{
    echo "$*" >> {shlex.quote(str(root / 'systemctl.log'))}
    {'if [[ $1 == stop && $2 == homeassistant ]]; then return 1; fi' if stop_failed else ':'}
    return 0
}}
apparmor_parser() {{ :; }}
logger() {{ :; }}
trap finish EXIT
false
'''
                result = subprocess.run(['bash', '-c', code], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 1, result.stderr)
                report = (backup / 'result.txt').read_text()
                self.assertIn(f'rollback_failed={str(stop_failed).lower()}', report)
                self.assertEqual(policy.read_text(), 'new policy' if stop_failed else 'old policy')
                self.assertEqual(new_unit.exists(), stop_failed)
                calls = (root / 'systemctl.log').read_text()
                self.assertEqual('start homeassistant' in calls, not stop_failed)
                self.assertNotIn('immich', calls)
                self.assertNotIn('jellyfin', calls)


if __name__ == '__main__':
    unittest.main()
