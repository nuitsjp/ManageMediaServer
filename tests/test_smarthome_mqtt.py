import importlib.util
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import test_smarthome as foundation_tests

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mqtt_check', ROOT/'scripts/ops/smarthome_mqtt.py')
MQTT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(MQTT)
sys.modules['smarthome_mqtt'] = MQTT
serial_spec = importlib.util.spec_from_file_location('provision', ROOT/'scripts/ops/provision-nanoc6-gateway.py')
PROVISION = importlib.util.module_from_spec(serial_spec)
serial_spec.loader.exec_module(PROVISION)
ha_spec = importlib.util.spec_from_file_location('ha_check', ROOT/'scripts/ops/check-smarthome-mqtt-ha.py')
HA = importlib.util.module_from_spec(ha_spec)
ha_spec.loader.exec_module(HA)


class ModelTests(unittest.TestCase):
    def test_usb_configuration_chunking_and_acknowledgement(self):
        master, slave = os.openpty()
        received = []
        def board():
            data = b''
            while b'\n' not in data:
                data += os.read(master,128)
            received.append(json.loads(data))
            os.write(master,b'{"v":1,"event":"configured"}\n')
        try:
            serial=PROVISION.Serial(os.ttyname(slave))
            thread=threading.Thread(target=board,daemon=True);thread.start()
            config=dict(command='configure',ca_pem='certificate-data'*250,wifi_password='test-only')
            serial.send(json.dumps(config))
            self.assertEqual(serial.receive(2)['event'],'configured')
            serial.close();thread.join(2)
            self.assertEqual(received,[config])
        finally:os.close(master);os.close(slave)

    def test_homeassistant_registry_matches_the_actual_mqtt_connection_and_sensor(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)
            entry=dict(entry_id='mqtt1',domain='mqtt',data=dict(broker='127.0.0.1',port=1883,username='homeassistant'))
            entities=[dict(platform='mqtt',config_entry_id='mqtt1',unique_id=f'nanoc6_a4c1380000000001_{kind}',
                           entity_id=f'sensor.test_{kind}',disabled_by=None) for kind in ('temperature','humidity')]
            (p/'core.config_entries').write_text(json.dumps(dict(data=dict(entries=[entry]))))
            (p/'core.entity_registry').write_text(json.dumps(dict(data=dict(entities=entities))))
            report=dict(measurements={'a4c1380000000001':dict(temperature={},humidity={})})
            self.assertEqual(len(HA.registered(p,report)['a4c1380000000001']),2)
            entities[0]['disabled_by']='user'
            (p/'core.entity_registry').write_text(json.dumps(dict(data=dict(entities=entities))))
            self.assertIsNone(HA.registered(p,report))
            entry['data']['broker']='another-broker'
            (p/'core.config_entries').write_text(json.dumps(dict(data=dict(entries=[entry]))))
            self.assertIsNone(HA.registered(p,report))

    def test_real_firmware_decoder_ten_devices_limits_and_stale_measurements(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = str(Path(directory)/'model')
            subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',
                            '-I'+str(ROOT/'firmware/nanoc6/wifi_gateway'),str(ROOT/'tests/nanoc6_gateway_model.cpp'),
                            '-o',binary],check=True,capture_output=True)
            subprocess.run([binary],check=True)

    def test_retained_historic_and_unnamed_messages_cannot_prove_live_devices(self):
        o = MQTT.Observation(started=time.time())
        state = 'smarthome/nanoc6/a4c1380000000001/temperature/state'
        payload = json.dumps({'value':27.2,'received_at':o.started-300}).encode()
        o.accept(state,payload)
        self.assertEqual(o.report()['complete_devices'],0)
        with self.assertRaisesRegex(ValueError,'retained'):
            o.accept(state,payload,True)
        with self.assertRaisesRegex(ValueError,'gateway_drops'):
            o.accept('smarthome/nanoc6/gateway/telemetry',json.dumps(dict(event_drops=0,job_drops=0,gateway_drops=1,device_overflow=0)).encode())

    def test_private_credentials_reject_links_permissions_and_fifo(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'credentials';p.write_text('{}');p.chmod(0o600)
            self.assertEqual(MQTT.private_json(p),{})
            p.chmod(0o644)
            with self.assertRaises(ValueError): MQTT.private_json(p)
            link=Path(directory)/'link';link.symlink_to(p)
            with self.assertRaises(OSError): MQTT.private_json(link)
            fifo=Path(directory)/'fifo';os.mkfifo(fifo,0o600)
            with self.assertRaises(ValueError): MQTT.private_json(fifo)


class MqttFirewallTests(unittest.TestCase):
    setUp = foundation_tests.FirewallTests.setUp

    def run_rules(self, command, fail=False):
        code = f'''
source {shlex.quote(str(ROOT/'scripts/ops/apply-smarthome-mqtt-firewall.sh'))}
iptables() {{ python3 {shlex.quote(str(self.model))} iptables "$@"; }}
ip6tables() {{ python3 {shlex.quote(str(self.model))} ip6tables "$@"; }}
LAN_CIDR=192.168.0.0/24
LAN_IFACE=enp1s0
{command}
'''
        env=dict(os.environ,RULE_STATE=str(self.state))
        if fail: env['FAIL_RULE']='1'
        return subprocess.run(['bash','-c',code],env=env,capture_output=True,text=True,timeout=15)

    def test_lan_cannot_reach_plaintext_and_unrelated_rules_survive(self):
        for _ in range(2):
            result=self.run_rules('apply_rules iptables; apply_rules ip6tables')
            self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(self.state.read_text())
        for tool,chains in data.items():
            self.assertEqual(chains['INPUT'][1:],self.original[tool]['INPUT'])
            self.assertEqual(chains['DOCKER-USER'],self.original[tool]['DOCKER-USER'])
            self.assertEqual(chains['MMS-MQTT'][0],['-i','lo','-j','ACCEPT'])
            self.assertEqual(chains['MMS-MQTT'][-1],['-j','DROP'])
        self.assertEqual(data['iptables']['MMS-MQTT'][1],['-i','enp1s0','-s','192.168.0.0/24','-p','tcp','--dport','8883','-j','ACCEPT'])
        self.assertEqual(len(data['ip6tables']['MMS-MQTT']),2)
        self.assertNotEqual(self.run_rules('apply_rules iptables',fail=True).returncode,0)
        self.assertEqual(json.loads(self.state.read_text())['iptables']['MMS-MQTT'][-1],['-j','DROP'])
        self.assertEqual(self.run_rules('remove_rules iptables; remove_rules ip6tables').returncode,0)
        self.assertEqual(json.loads(self.state.read_text()),self.original)


class DeploymentSafetyTests(unittest.TestCase):
    setUp = foundation_tests.DeploymentTests.setUp

    def test_rendered_compose_mounts_are_accepted_and_unquoted_commas_are_rejected(self):
        compose=ROOT/'docker/mosquitto/docker-compose.yml'
        command=MQTT.container_check_command(compose)
        mounts=[command[i+1] for i,value in enumerate(command) if value=='--tmpfs']
        self.assertEqual(mounts,['/tmp:size=8m,mode=1777'])
        self.assertEqual(command[command.index('--user')+1],'1883:1883')
        self.assertIn('--read-only',command)
        with tempfile.TemporaryDirectory() as directory:
            broken=Path(directory)/'compose.yml'
            text=compose.read_text().replace('tmpfs:\n      - "/tmp:size=8m,mode=1777"',
                                             'tmpfs: [/tmp:size=8m,mode=1777]')
            self.assertNotEqual(text,compose.read_text())
            broken.write_text(text)
            with self.assertRaisesRegex(ValueError,'absolute paths'):
                MQTT.container_check_command(broken)

    def test_saved_credentials_are_reused_privately_without_password_input(self):
        source=(ROOT/'scripts/ops/install-smarthome-mqtt.sh').read_text()
        helper=source.split('python3 - "$REPO/scripts/ops" "$REUSE_CREDENTIALS" "$CLIENTS" <<\'PY\'\n',1)[1].split('\nPY',1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);saved=root/'saved.json';target=root/'restored.json'
            config=dict(host='192.168.0.23',passwords={user:'not-real-but-long-enough' for user in ('homeassistant','nanoc6','smarthome-check')})
            saved.write_text(json.dumps(config));saved.chmod(0o600)
            code=helper.replace("'/mnt/backup/smarthome/'",repr(str(root)+'/'))
            result=subprocess.run([sys.executable,'-',str(ROOT/'scripts/ops'),str(saved),str(target)],input=code,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(target.read_text()),config)
            self.assertEqual(target.stat().st_mode&0o777,0o600)
            self.assertNotIn('not-real-but-long-enough',result.stdout+result.stderr)
            target.unlink();saved.chmod(0o644)
            result=subprocess.run([sys.executable,'-',str(ROOT/'scripts/ops'),str(saved),str(target)],input=code,text=True,capture_output=True)
            self.assertNotEqual(result.returncode,0);self.assertFalse(target.exists())

    def test_mqtt_only_deploy_preserves_ha_media_and_private_settings(self):
        for tree in ('docker/mosquitto','config/mosquitto','firmware/nanoc6/wifi_gateway'):
            shutil.copytree(ROOT/tree,self.repo/tree)
        for path in ('docs/NanoC6-MQTT連携.md','systemd/smarthome-mqtt.service','systemd/smarthome-mqtt-firewall.service',
                     'scripts/ops/apply-smarthome-mqtt-firewall.sh','scripts/ops/install-smarthome-mqtt.sh',
                     'scripts/ops/smarthome_mqtt.py','scripts/ops/provision-nanoc6-gateway.py',
                     'scripts/ops/update-nanoc6-gateway.sh','scripts/ops/check-smarthome-mqtt-ha.py','scripts/ops/build-nanoc6-gateway.sh'):
            target=self.repo/path;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/path,target)
        subprocess.run(['git','-C',str(self.repo),'add','.'],check=True)
        sentinels=('docker/homeassistant/docker-compose.yml','docker/immich/.env','config/env/notification.env')
        for path in sentinels:
            target=self.prod/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_text('preserve')
        command=['bash',str(self.repo/'scripts/ops/deploy-managed-files.sh'),'--mqtt-only']
        result=subprocess.run(command,env=self.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        for path in sentinels:self.assertEqual((self.prod/path).read_text(),'preserve')
        self.assertTrue((self.systemd/'smarthome-mqtt.service').exists())
        self.assertFalse((self.systemd/'homeassistant.service').exists())
        self.assertEqual((self.prod/'config/mosquitto/acl').read_bytes(),(ROOT/'config/mosquitto/acl').read_bytes())

    def test_failed_install_keeps_live_broker_data_when_stop_cannot_be_proven(self):
        source=(ROOT/'scripts/ops/install-smarthome-mqtt.sh').read_text()
        function=re.search(r'^finish\(\) \{\n.*?^\}',source,re.M|re.S)[0]
        for stopped in (True,False):
            with self.subTest(stopped=stopped),tempfile.TemporaryDirectory() as directory:
                p=Path(directory);backup=p/'backup';backup.mkdir()
                data=p/'mosquitto';data.mkdir();(data/'secret').write_text('private')
                private=p/'private';private.mkdir();clients=p/'clients.json';clients.write_text('{}')
                target=p/'managed';target.write_text('new')
                saved=backup/'files'/str(target).lstrip('/');saved.parent.mkdir(parents=True);saved.write_text('old')
                (backup/'targets.txt').write_text(str(target)+'\n')
                repo=p/'repo';ops=repo/'scripts/ops';ops.mkdir(parents=True)
                (ops/'apply-smarthome-mqtt-firewall.sh').write_text('exit 0\n')
                code=f'''set -euo pipefail
{function}
BACKUP={shlex.quote(str(backup))}
DATA={shlex.quote(str(data))}
PRIVATE={shlex.quote(str(private))}
CLIENTS={shlex.quote(str(clients))}
REPO={shlex.quote(str(repo))}
COMPOSE=unused
STAGE=verify
DEPLOYED=true
STARTED_AT='2026-11-07 00:00:00 UTC'
systemctl() {{ return 0; }}
 journalctl() {{ :; }}
docker() {{ if [[ $1 == ps ]]; then return {0 if stopped else 1}; fi; return 0; }}
logger() {{ :; }}
trap finish EXIT
exit 2
'''
                result=subprocess.run(['bash','-c',code],capture_output=True,text=True,timeout=5)
                self.assertEqual(result.returncode,2,result.stderr)
                if stopped:
                    self.assertEqual((backup/'mosquitto/secret').read_text(),'private')
                    self.assertFalse(data.exists());self.assertEqual(target.read_text(),'old')
                else:
                    self.assertEqual((data/'secret').read_text(),'private')
                    self.assertEqual(target.read_text(),'new')
                    self.assertIn('rollback_failed=true',result.stdout)

    def test_flash_readback_guard_rejects_changes_to_paired_network_storage(self):
        source=(ROOT/'scripts/ops/update-nanoc6-gateway.sh').read_text()
        guard=source.split('python3 - "$BUILD" "$BACKUP" <<\'PY\'\n',1)[1].split('\nPY',1)[0]
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory);build=p/'build';backup=p/'backup';build.mkdir();backup.mkdir()
            before=bytes([0x7f])*4194304
            (backup/'original-flash.bin').write_bytes(before)
            after=bytearray(before)
            for start,name in ((0x8000,'wifi_gateway.ino.partitions.bin'),(0x10000,'wifi_gateway.ino.bin')):
                (build/name).write_bytes(b'new-reviewed-image');after[start:start+18]=b'new-reviewed-image'
            (backup/'updated-flash.bin').write_bytes(after)
            command=[sys.executable,'-',str(build),str(backup)]
            result=subprocess.run(command,input=guard,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            for offset in (0x9000,0x3ea000):
                corrupted=bytearray(after);corrupted[offset]=0
                (backup/'updated-flash.bin').write_bytes(corrupted)
                result=subprocess.run(command,input=guard,text=True,capture_output=True)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('Preserved storage changed',result.stderr)


# The exact production image can be extracted under a user-local cache; no daemon,
# root permissions or OS package installation are needed for this integration test.
RUNTIME = Path(os.environ.get('MOSQUITTO_TEST_RUNTIME','/home/ubuntu/.cache/manage-media-smarthome/mosquitto-test-runtime'))


@unittest.skipUnless((RUNTIME/'usr/sbin/mosquitto').exists(), 'Set MOSQUITTO_TEST_RUNTIME to the extracted pinned image')
class BrokerTests(unittest.TestCase):
    def runtime(self,binary,*args):
        return [str(RUNTIME/'lib/ld-musl-x86_64.so.1'),'--library-path',f'{RUNTIME}/lib:{RUNTIME}/usr/lib',str(RUNTIME/binary),*args]

    def test_tls_auth_acl_retained_discovery_and_ten_device_delivery(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)
            for user in ('nanoc6','homeassistant','smarthome-check'):
                with (p/'passwords').open('a') as f:f.write(user+':test-mqtt-password-123456\n')
            subprocess.run(self.runtime('usr/bin/mosquitto_passwd','-U',str(p/'passwords')),check=True,capture_output=True)
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-sha256','-nodes','-days','1',
                            '-subj','/CN=localhost','-addext','subjectAltName=IP:127.0.0.1,DNS:localhost',
                            '-keyout',str(p/'key'),'-out',str(p/'ca')],check=True,capture_output=True)
            with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
            with socket.socket() as s:s.bind(('127.0.0.1',0));local_port=s.getsockname()[1]
            config=(ROOT/'config/mosquitto/mosquitto.conf').read_text()
            config=config.replace('listener 1883 127.0.0.1',f'listener {local_port} 127.0.0.1').replace('listener 8883 0.0.0.0',f'listener {port} 127.0.0.1')
            config=config.replace('/mosquitto/config/passwords',str(p/'passwords')).replace('/mosquitto/config/acl',str(ROOT/'config/mosquitto/acl'))
            config=config.replace('/mosquitto/config/server.crt',str(p/'ca')).replace('/mosquitto/config/server.key',str(p/'key'))
            config=config.replace('persistence true','persistence false')
            (p/'config').write_text(config)
            with (p/'log').open('w') as log:
                broker=subprocess.Popen(self.runtime('usr/sbin/mosquitto','-c',str(p/'config')),stdout=log,stderr=log)
                clients=[]
                try:
                    for _ in range(50):
                        if broker.poll() is not None:self.fail((p/'log').read_text())
                        try:
                            c=MQTT.Client('127.0.0.1',port,'smarthome-check','test-mqtt-password-123456',p/'ca')
                            clients.append(c);break
                        except ConnectionRefusedError:time.sleep(0.05)
                    else:self.fail('Broker did not start')
                    with self.assertRaises(ConnectionError):MQTT.Client('127.0.0.1',port,'nanoc6','incorrect',p/'ca')
                    local=MQTT.Client('127.0.0.1',local_port,'homeassistant','test-mqtt-password-123456');clients.append(local)
                    with self.assertRaises(ssl.SSLCertVerificationError):self.bad_ca(port)
                    publisher=MQTT.Client('127.0.0.1',port,'nanoc6','test-mqtt-password-123456',p/'ca');clients.append(publisher)
                    observer=MQTT.Observation()
                    c.subscribe('homeassistant/sensor/nanoc6/#');c.subscribe('smarthome/nanoc6/#')
                    for i in range(10):
                        ieee=f'a4c138{i+1:010x}'
                        for kind,value in (('temperature',27.2+i/100),('humidity',43.67+i/100)):
                            topic=f'smarthome/nanoc6/{ieee}/{kind}/state'
                            config=dict(unique_id=f'nanoc6_{ieee}_{kind}',state_topic=topic,device=dict(identifiers=[f'nanoc6_{ieee}']))
                            publisher.publish(f'homeassistant/sensor/nanoc6/{ieee}_{kind}/config',json.dumps(config),True)
                            publisher.publish(topic,json.dumps(dict(value=value,received_at=time.time())))
                    publisher.publish('smarthome/nanoc6/gateway/availability','online',True)
                    end=time.monotonic()+5
                    while time.monotonic()<end and observer.report()['complete_devices']<10:
                        message=c.receive()
                        if message:observer.accept(*message)
                    self.assertEqual(observer.report()['complete_devices'],10)
                    # Reconnecting clients get retained discovery, never old state values.
                    new=MQTT.Client('127.0.0.1',port,'homeassistant','test-mqtt-password-123456',p/'ca');clients.append(new)
                    new.subscribe('homeassistant/sensor/nanoc6/#');new.subscribe('smarthome/nanoc6/#')
                    retained=[]
                    end=time.monotonic()+1
                    while time.monotonic()<end:
                        message=new.receive(0.1)
                        if message:retained.append(message)
                    self.assertEqual(len([m for m in retained if m[0].startswith('homeassistant/')]),20)
                    self.assertFalse(any(m[0].endswith('/state') for m in retained))
                    # A diagnostics user cannot forge sensor data or discovery.
                    c.publish('smarthome/nanoc6/a4c1380000000001/temperature/state','{"value":99}')
                    end=time.monotonic()+0.3
                    while time.monotonic()<end:
                        message=new.receive(0.1)
                        self.assertFalse(message and b'99' in message[1])
                finally:
                    for client in clients:client.close()
                    broker.terminate();broker.wait(timeout=5)

    def bad_ca(self,port):
        raw=socket.create_connection(('127.0.0.1',port),timeout=2)
        try:ssl.create_default_context().wrap_socket(raw,server_hostname='127.0.0.1')
        finally:raw.close()


if __name__=='__main__':unittest.main()
