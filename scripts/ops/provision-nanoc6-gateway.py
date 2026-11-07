#!/usr/bin/env python3
"""Provision over USB, then verify NEW Zigbee measurements over MQTT/TLS."""
import argparse
import getpass
import json
import os
from pathlib import Path
import select
import sys
import termios
import threading
import time

from smarthome_mqtt import Observation, connect, private_json

PORT = '/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_9C:CC:01:33:A1:50-if00'


class Serial:
    def __init__(self, port=PORT):
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.previous = termios.tcgetattr(self.fd)
        settings = list(self.previous)
        settings[0] = settings[1] = settings[3] = 0
        settings[2] = termios.CS8 | termios.CLOCAL | termios.CREAD
        settings[4] = settings[5] = termios.B115200
        settings[6] = list(self.previous[6])
        settings[6][termios.VMIN], settings[6][termios.VTIME] = 0, 1
        termios.tcsetattr(self.fd, termios.TCSANOW, settings)
        self.buffer = b''

    def send(self, command):
        remaining = (command + '\n').encode()
        deadline = time.monotonic() + 15
        while remaining:
            if time.monotonic() > deadline:
                raise TimeoutError('USB command timeout')
            if select.select([], [self.fd], [], 0.5)[1]:
                try:
                    size = os.write(self.fd, remaining[:128])
                except BlockingIOError:
                    continue
                remaining = remaining[size:]
                time.sleep(0.01)

    def receive(self, timeout=1):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                try:
                    event = json.loads(line)
                    if isinstance(event, dict) and event.get('v') == 1:
                        return event
                except (ValueError, UnicodeError):
                    pass
                continue
            if select.select([self.fd], [], [], min(0.2, max(0, end-time.monotonic())))[0]:
                data = os.read(self.fd, 4096)
                if not data:
                    continue
                self.buffer += data
                if len(self.buffer) > 65536:
                    raise ValueError('Oversized USB line')
        return None

    def close(self):
        try:
            termios.tcsetattr(self.fd, termios.TCSANOW, self.previous)
        except OSError:
            pass  # Native USB may disappear during ESP.restart().
        finally:
            os.close(self.fd)


def provision_config(path, clients, ca, evidence):
    if path.exists():
        config = private_json(path)
        if config.get('mqtt_password') != clients['passwords']['nanoc6'] or config.get('ca_pem') != ca.read_text():
            raise ValueError('Saved provisioning configuration differs from the broker. Preserve it and ask for repair.')
        return config
    if not sys.stdin.isatty():
        raise ValueError('An interactive terminal is required for Wi-Fi credentials')
    ssid = input('2.4 GHz Wi-Fi SSID: ')
    password = getpass.getpass('Wi-Fi password (hidden; never printed or stored in Git): ')
    if not 1 <= len(ssid.encode()) <= 32 or not 8 <= len(password.encode()) <= 63:
        raise ValueError('Use a 2.4 GHz WPA2/WPA3 network with an 8..63 byte password and SSID up to 32 bytes')
    devices = []
    for device in json.loads(evidence.read_text())['devices']:
        if device.get('complete'):
            devices.append({k: device[k] for k in ('ieee', 'manufacturer', 'model')})
    config = dict(command='configure', wifi_ssid=ssid, wifi_password=password, mqtt_host=clients['host'],
                  mqtt_user='nanoc6', mqtt_password=clients['passwords']['nanoc6'], ca_pem=ca.read_text(), devices=devices)
    if len(json.dumps(config, ensure_ascii=False).encode()) > 5500:
        raise ValueError('Provisioning message is too large')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(config, stream, ensure_ascii=False)
    return config


def run(args):
    clients = private_json(args.credentials)
    config = provision_config(args.config, clients, args.ca, args.evidence)
    output = args.output
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    observation = Observation()
    client = connect(clients, args.ca)
    client.subscribe('smarthome/nanoc6/#')
    client.subscribe('homeassistant/sensor/nanoc6/#')
    stop = threading.Event()
    error = []

    def listener():
        try:
            while not stop.is_set():
                message = client.receive()
                if message:
                    observation.accept(*message)
        except BaseException as exc:
            error.append(exc)

    thread = threading.Thread(target=listener, daemon=True)
    thread.start()
    serial = None
    gateway_ready = False
    last_gateway_status = None
    try:
        serial = Serial()
        serial.send(json.dumps(config, ensure_ascii=False))
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            event = serial.receive()
            if event and event.get('event') == 'configured':
                break
            if event and event.get('event') == 'invalid_config':
                raise ValueError('Nano C6 rejected configuration')
        else:
            raise RuntimeError('No configuration acknowledgement. Reconnect without pressing the boot button.')
        serial.close(); serial = None
        time.sleep(2)
        deadline = time.monotonic() + args.duration
        last_status, interviewed = 0, False
        while time.monotonic() < deadline:
            if error:
                raise RuntimeError('MQTT observation failed') from error[0]
            if serial is None:
                try:
                    serial = Serial()
                except OSError:
                    time.sleep(1)
                    continue
            try:
                if time.monotonic() - last_status > 3:
                    serial.send('gateway-status')
                    last_status = time.monotonic()
                event = serial.receive(0.5)
            except OSError:
                serial.close(); serial = None
                continue
            if event and event.get('event') == 'gateway_status':
                (output/'serial-status.json').write_text(json.dumps(event, indent=2)+'\n')
                status = tuple(bool(event.get(k)) for k in ('wifi', 'mqtt', 'clock'))
                if status != last_gateway_status:
                    print(f'Gateway: Wi-Fi={status[0]} MQTT/TLS={status[1]} clock={status[2]}', flush=True)
                    last_gateway_status = status
                gateway_ready = bool(event.get('mqtt') and event.get('wifi') and event.get('clock'))
                if gateway_ready and not interviewed:
                    print('Wi-Fi and verified MQTT/TLS connected. Waiting for fresh Zigbee temperature/humidity...', flush=True)
                    # The known sensor remains paired; discover its current address from the original evidence.
                    report = json.loads(args.evidence.read_text())
                    for device in report['devices']:
                        if device.get('complete') and type(device.get('short')) is int:
                            serial.send(f"interview {device['short']:04x}")
                    interviewed = True
            report = observation.report()
            if gateway_ready and report['online'] and report['complete_devices'] >= 1 and report['telemetry']:
                print('Fresh temperature and humidity received over MQTT/TLS; no gateway queue loss.', flush=True)
                return 0
        raise RuntimeError('Live MQTT measurements were not verified in time. Evidence saved; no automatic reflash.')
    finally:
        if serial:
            serial.close()
        stop.set(); thread.join(3)
        client.close()
        (output/'mqtt-report.json').write_text(json.dumps(observation.report(), ensure_ascii=False, indent=2)+'\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials', type=Path, default=Path('/etc/manage-smarthome/mqtt-clients.json'))
    parser.add_argument('--config', type=Path, default=Path('/etc/manage-smarthome/nanoc6-provision.json'))
    parser.add_argument('--ca', type=Path, default=Path('/mnt/data/smarthome/mosquitto/config/ca.crt'))
    parser.add_argument('--evidence', type=Path, default=Path('/mnt/data/smarthome/nanoc6/diagnostics/redecoded-MEmLyEbm/report.json'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--duration', type=int, default=300)
    args = parser.parse_args()
    if not 60 <= args.duration <= 3600:
        parser.error('duration must be 60..3600')
    return run(args)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
