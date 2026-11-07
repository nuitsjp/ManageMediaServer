#!/usr/bin/env python3
"""Small MQTT 3.1.1 verification client; no host package installation required."""
import argparse
import getpass
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import stat
import struct
import subprocess
import sys
import threading
import time


def private_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or info.st_size > 65536:
            raise ValueError('Credentials must be a private regular file owned by the current user')
        return json.load(stream)


def mqtt_string(value):
    raw = value.encode() if isinstance(value, str) else value
    if len(raw) > 65535:
        raise ValueError('MQTT string too long')
    return struct.pack('!H', len(raw)) + raw


class Client:
    def __init__(self, host, port, username, password, ca=None):
        raw = socket.create_connection((host, port), timeout=10)
        try:
            self.socket = ssl.create_default_context(cafile=str(ca)).wrap_socket(raw, server_hostname=host) if ca else raw
            self.socket.settimeout(1)
            self.buffer = bytearray()
            self.identifier = 0
            self.last_ping = time.monotonic()
            client_id = 'smarthome-check-' + secrets.token_hex(5)
            self.send(0x10, mqtt_string('MQTT') + bytes([4, 0xc2]) + struct.pack('!H', 30)
                      + mqtt_string(client_id) + mqtt_string(username) + mqtt_string(password))
            header, body = self.packet(10)
            if header != 0x20 or len(body) != 2 or body[1] != 0:
                raise ConnectionError('MQTT authentication failed')
        except BaseException:
            if hasattr(self, 'socket'):
                self.socket.close()
            else:
                raw.close()
            raise

    def send(self, header, body=b''):
        length = len(body)
        encoded = bytearray([header])
        while True:
            digit = length % 128
            length //= 128
            encoded.append(digit | (128 if length else 0))
            if not length:
                break
        self.socket.sendall(encoded + body)

    def packet(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            if len(self.buffer) >= 2:
                length, factor, offset = 0, 1, 1
                while offset < len(self.buffer):
                    digit = self.buffer[offset]
                    offset += 1
                    length += (digit & 127) * factor
                    if length > 65536 or offset > 5:
                        raise ValueError('Oversized MQTT packet')
                    if not digit & 128:
                        if len(self.buffer) >= offset + length:
                            header, body = self.buffer[0], bytes(self.buffer[offset:offset+length])
                            del self.buffer[:offset+length]
                            return header, body
                        break
                    factor *= 128
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('MQTT receive timeout')
            if time.monotonic() - self.last_ping > 15:
                self.send(0xc0)
                self.last_ping = time.monotonic()
            self.socket.settimeout(min(remaining, 1))
            try:
                data = self.socket.recv(4096)
            except socket.timeout:
                continue
            if not data:
                raise ConnectionError('MQTT connection closed')
            self.buffer.extend(data)

    def next_id(self):
        self.identifier = self.identifier % 65535 + 1
        return self.identifier

    def subscribe(self, topic):
        identifier = self.next_id()
        self.send(0x82, struct.pack('!H', identifier) + mqtt_string(topic) + b'\x01')

    def publish(self, topic, payload, retain=False):
        identifier = self.next_id()
        self.send(0x32 | bool(retain), mqtt_string(topic) + struct.pack('!H', identifier) + payload.encode())
        return identifier

    def receive(self, timeout=1):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                header, body = self.packet(max(0.01, deadline-time.monotonic()))
            except TimeoutError:
                return None
            if header >> 4 == 9:
                if len(body) < 3 or any(code == 128 for code in body[2:]):
                    raise PermissionError('MQTT subscription denied')
            elif header >> 4 == 3:
                size = struct.unpack('!H', body[:2])[0]
                topic = body[2:2+size].decode()
                offset = 2 + size
                qos = (header >> 1) & 3
                if qos == 1:
                    self.send(0x40, body[offset:offset+2])
                    offset += 2
                elif qos:
                    raise ValueError('Unexpected MQTT QoS')
                return topic, body[offset:], bool(header & 1)
        return None

    def close(self):
        try:
            self.send(0xe0)
        except OSError:
            pass
        self.socket.close()


class Observation:
    def __init__(self, started=None):
        self.lock = threading.RLock()
        self.started = time.time() if started is None else started
        self.measurements, self.discovery = {}, set()
        self.online = False
        self.telemetry = None

    def accept(self, topic, payload, retained=False):
        with self.lock:
            self._accept(topic, payload, retained)

    def _accept(self, topic, payload, retained=False):
        if topic == 'smarthome/nanoc6/gateway/availability':
            self.online = payload == b'online'
        elif topic.startswith('homeassistant/sensor/nanoc6/'):
            data = json.loads(payload)
            state = data.get('state_topic', '')
            match = re.fullmatch(r'smarthome/nanoc6/([a-f0-9]{16})/(temperature|humidity|battery|voltage)/state', state)
            if (match and data.get('unique_id') == f'nanoc6_{match[1]}_{match[2]}'
                    and data.get('device', {}).get('identifiers') == [f'nanoc6_{match[1]}']):
                self.discovery.add((match[1], match[2]))
        elif topic == 'smarthome/nanoc6/gateway/telemetry':
            data = json.loads(payload)
            for key in ('event_drops', 'job_drops', 'gateway_drops', 'device_overflow'):
                if type(data.get(key)) is not int or data[key] != 0:
                    raise ValueError(f'Gateway evidence failed: {key}')
            self.telemetry = data
        else:
            match = re.fullmatch(r'smarthome/nanoc6/([a-f0-9]{16})/(temperature|humidity|battery|voltage)/state', topic)
            if not match:
                return
            data = json.loads(payload)
            if retained:
                raise ValueError('Measurement unexpectedly retained')
            timestamp, value = data.get('received_at'), data.get('value')
            if type(timestamp) not in (int, float) or not math.isfinite(timestamp) or not self.started-2 <= timestamp <= time.time()+2:
                return  # Historic measurements must not prove a new live reception.
            if type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError('Invalid measurement')
            if match[2] in ('humidity', 'battery') and not 0 <= value <= 100:
                raise ValueError('Invalid percentage')
            self.measurements.setdefault(match[1], {})[match[2]] = data

    def report(self):
        with self.lock:
            complete = sum(all(kind in values and (ieee, kind) in self.discovery for kind in ('temperature', 'humidity'))
                           for ieee, values in self.measurements.items())
            return json.loads(json.dumps(dict(complete_devices=complete, online=self.online, telemetry=self.telemetry,
                                             measurements=self.measurements, started_at=self.started)))


def connect(config, ca, username='smarthome-check', local=False):
    return Client('127.0.0.1' if local else config['host'], 1883 if local else 8883,
                  username, config['passwords'][username], None if local else ca)


def check(config, ca):
    client = connect(config, ca)
    try:
        topic, nonce = 'smarthome/check/' + secrets.token_hex(6), secrets.token_hex(16)
        client.subscribe(topic)
        client.publish(topic, nonce)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            message = client.receive()
            if message and message[:2] == (topic, nonce.encode()):
                break
        else:
            raise RuntimeError('Authenticated TLS loopback failed')
    finally:
        client.close()
    local = connect(config, ca, 'homeassistant', local=True)
    local.close()
    try:
        invalid = Client(config['host'], 8883, 'smarthome-check', 'invalid-password', ca)
    except ConnectionError:
        pass
    else:
        invalid.close()
        raise RuntimeError('Bad MQTT credentials were accepted')
    print('MQTT TLS certificate/hostname, authenticated delivery, HA local credentials and bad-password rejection: OK')


def container_check_command(compose):
    # Use Compose's rendered values, including YAML list parsing, rather than
    # independently recreating the mount options for this startup preflight.
    rendered = json.loads(subprocess.check_output(
        ['docker', 'compose', '-f', str(compose), 'config', '--format', 'json'], text=True))
    service = rendered['services']['mosquitto']
    mounts = service.get('tmpfs', [])
    if isinstance(mounts, str):
        mounts = [mounts]
    if not mounts or any(not isinstance(mount, str) or not mount.split(':', 1)[0].startswith('/') for mount in mounts):
        raise ValueError('Compose tmpfs targets must be absolute paths; quote entries containing commas')
    if not service.get('read_only') or service.get('user') != '1883:1883':
        raise ValueError('Expected read-only broker with the dedicated unprivileged user')
    command = ['docker', 'run', '--rm', '--network', 'none', '--read-only', '--user', service['user']]
    for capability in service.get('cap_drop', []):
        command += ['--cap-drop', capability]
    for option in service.get('security_opt', []):
        command += ['--security-opt', option]
    for mount in mounts:
        command += ['--tmpfs', mount]
    return command + ['--entrypoint', '/bin/sh', service['image'], '-ec',
                      'test -w /tmp; touch /tmp/mqtt-container-check; rm /tmp/mqtt-container-check']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('init', 'check', 'observe', 'container-check'))
    parser.add_argument('--compose', type=Path)
    parser.add_argument('--credentials', type=Path, default=Path('/etc/manage-smarthome/mqtt-clients.json'))
    parser.add_argument('--ca', type=Path, default=Path('/mnt/data/smarthome/mosquitto/config/ca.crt'))
    parser.add_argument('--host', default='192.168.0.23')
    parser.add_argument('--duration', type=int, default=180)
    parser.add_argument('--expected-devices', type=int, default=1)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.action == 'container-check':
        if not args.compose:
            parser.error('--compose is required for container-check')
        try:
            subprocess.run(container_check_command(args.compose), check=True)
        except subprocess.CalledProcessError as error:
            raise RuntimeError('Broker container preflight failed; no credentials or running services were changed') from error
        print('Rendered Compose tmpfs and unprivileged read-only container startup: OK')
        return 0
    if args.action == 'init':
        if args.credentials.exists() or args.credentials.is_symlink():
            raise ValueError('Credentials already exist')
        if not ipaddress.ip_address(args.host).is_private or not sys.stdin.isatty():
            raise ValueError('Private broker IPv4 address and an interactive terminal are required')
        password = getpass.getpass('Choose a NEW MQTT password for Home Assistant (16+ characters; remember it for the HA UI): ')
        if len(password) < 16 or password != getpass.getpass('Confirm MQTT password: ') or '\n' in password or '\r' in password:
            raise ValueError('Password confirmation failed or password is too short')
        config = {'host': args.host, 'passwords': {'homeassistant': password, 'nanoc6': secrets.token_urlsafe(32),
                                                'smarthome-check': secrets.token_urlsafe(32)}}
        fd = os.open(args.credentials, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(config, stream)
        print('MQTT credentials saved privately. No passwords are printed.')
    else:
        config = private_json(args.credentials)
        if args.action == 'check':
            check(config, args.ca)
        else:
            if not args.output or not 1 <= args.expected_devices <= 20 or not 1 <= args.duration <= 86400:
                raise ValueError('Output, duration 1..86400 and expected-devices 1..20 are required')
            observation, client = Observation(), connect(config, args.ca)
            client.subscribe('smarthome/nanoc6/#')
            client.subscribe('homeassistant/sensor/nanoc6/#')
            try:
                end = time.monotonic() + args.duration
                while time.monotonic() < end:
                    message = client.receive()
                    if message:
                        observation.accept(*message)
                    report = observation.report()
                    if report['complete_devices'] >= args.expected_devices and report['online'] and report['telemetry']:
                        break
            finally:
                client.close()
                args.output.write_text(json.dumps(observation.report(), indent=2) + '\n')
            report = observation.report()
            print(json.dumps(report, indent=2))
            return 0 if report['complete_devices'] >= args.expected_devices and report['online'] and report['telemetry'] else 2
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
