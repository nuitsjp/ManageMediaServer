#!/usr/bin/env python3
"""Run inside HA: verify bus subscription, BlueZ and active host scanning.

This does not start discovery or pair a device. No addresses or device values
are included in the report. A successful HTTP response cannot replace this test.
"""
import asyncio
import json
import sys


class ProbeError(Exception):
    pass


async def check_bluez(bus, message, error_type):
    async def call(**kwargs):
        reply = await bus.call(message(**kwargs))
        if reply.message_type == error_type:
            raise ProbeError(reply.error_name or 'DBusError')
        return reply

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
    return {'status': 'ok', 'adapters': len(adapters), 'powered': powered, 'scanning': discovering}


async def probe():
    from dbus_fast import BusType, Message, MessageType
    from dbus_fast.aio import MessageBus

    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    try:
        return await check_bluez(bus, Message, MessageType.ERROR)
    finally:
        bus.disconnect()


def main():
    try:
        report = asyncio.run(asyncio.wait_for(probe(), timeout=15))
    except Exception as error:
        # Print only the error class/name, never raw D-Bus objects or sensor data.
        report = {'status': 'failed', 'error': str(error) if isinstance(error, ProbeError) else type(error).__name__}
    print(json.dumps(report, ensure_ascii=True))
    return 0 if report['status'] == 'ok' else 1


if __name__ == '__main__':
    sys.exit(main())
