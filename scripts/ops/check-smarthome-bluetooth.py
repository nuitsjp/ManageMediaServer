#!/usr/bin/env python3
"""Run inside HA: verify BlueZ and receipt of live Bluetooth device signals.

This does not start discovery or pair a device. No addresses or device values
are included in the report. A successful HTTP response cannot replace this test.
"""
import asyncio
import json
import sys


class ProbeError(Exception):
    pass


async def check_bluez(bus, message, error_type, signal_type, signal_timeout=30):
    received = asyncio.Event()
    device_signals = 0

    def on_message(event):
        nonlocal device_signals
        if event.message_type != signal_type:
            return
        properties = (event.interface == 'org.freedesktop.DBus.Properties'
                      and event.member == 'PropertiesChanged'
                      and (event.path or '').startswith('/org/bluez/')
                      and '/dev_' in event.path and event.body
                      and event.body[0] == 'org.bluez.Device1')
        added = (event.interface == 'org.freedesktop.DBus.ObjectManager'
                 and event.member == 'InterfacesAdded' and event.path == '/'
                 and len(event.body) == 2 and 'org.bluez.Device1' in event.body[1])
        if properties or added:
            device_signals += 1
            received.set()

    async def call(**kwargs):
        reply = await bus.call(message(**kwargs))
        if reply.message_type == error_type:
            raise ProbeError(reply.error_name or 'DBusError')
        return reply

    bus.add_message_handler(on_message)
    try:
        await call(destination='org.freedesktop.DBus', path='/org/freedesktop/DBus',
                   interface='org.freedesktop.DBus', member='AddMatch', signature='s',
                   body=["type='signal',sender='org.bluez'"])
        reply = await call(destination='org.bluez', path='/',
                           interface='org.freedesktop.DBus.ObjectManager', member='GetManagedObjects')
        adapters = [interfaces['org.bluez.Adapter1'] for interfaces in reply.body[0].values()
                    if 'org.bluez.Adapter1' in interfaces]
        powered = sum(bool(adapter.get('Powered') and adapter['Powered'].value) for adapter in adapters)
        discovering = sum(bool(adapter.get('Powered') and adapter['Powered'].value
                               and adapter.get('Discovering') and adapter['Discovering'].value)
                          for adapter in adapters)
        if not adapters:
            raise ProbeError('NoBlueZAdapter')
        if not powered:
            raise ProbeError('AdapterNotPowered')
        if not discovering:
            raise ProbeError('AdapterNotScanning')
        try:
            await asyncio.wait_for(received.wait(), timeout=signal_timeout)
        except TimeoutError as error:
            raise ProbeError('NoLiveDeviceSignals') from error
        return {'status': 'ok', 'adapters': len(adapters), 'powered': powered,
                'scanning': discovering, 'received_device_signals': device_signals}
    finally:
        bus.remove_message_handler(on_message)


async def probe():
    from dbus_fast import BusType, Message, MessageType
    from dbus_fast.aio import MessageBus

    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    try:
        return await check_bluez(bus, Message, MessageType.ERROR, MessageType.SIGNAL)
    finally:
        bus.disconnect()


def main():
    try:
        report = asyncio.run(asyncio.wait_for(probe(), timeout=45))
    except Exception as error:
        # Print only the error class/name, never raw D-Bus objects or sensor data.
        report = {'status': 'failed', 'error': str(error) if isinstance(error, ProbeError) else type(error).__name__}
    print(json.dumps(report, ensure_ascii=True))
    return 0 if report['status'] == 'ok' else 1


if __name__ == '__main__':
    sys.exit(main())
