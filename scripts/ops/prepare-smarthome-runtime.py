#!/usr/bin/env python3
"""Prepare volatile lock directories after boot; reject unsafe existing paths."""
import os
from pathlib import Path
import stat
import sys


def ensure_directory(path, mode, owner_uid=0):
    try:
        path.mkdir(mode=mode)
    except FileExistsError:
        pass
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != owner_uid or info.st_mode & 0o022:
        raise ValueError(f'Unprotected runtime directory: {path}')


def ensure_lock(path, owner_uid=0):
    # O_NONBLOCK avoids waiting on an unexpected FIFO; O_NOFOLLOW rejects links.
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != owner_uid or info.st_mode & 0o022:
            raise ValueError(f'Unprotected runtime lock: {path}')
    finally:
        os.close(fd)


def prepare(runtime_root=Path('/run'), owner_uid=0):
    for name, mode, lock in (
        ('manage-smarthome', 0o700, 'install.lock'),
        ('manage-media-maintenance', 0o755, 'daily.lock'),
    ):
        directory = runtime_root / name
        ensure_directory(directory, mode, owner_uid)
        ensure_lock(directory / lock, owner_uid)


def main():
    if len(sys.argv) != 1 or os.geteuid() != 0:
        print('Run with sudo, without arguments.', file=sys.stderr)
        return 1
    try:
        prepare()
    except (OSError, ValueError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1
    print('Runtime lock directories are ready (created missing paths; preserved existing locks).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
