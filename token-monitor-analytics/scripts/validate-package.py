#!/usr/bin/env python3
"""Validate a checked archive and unpack only ordinary files/directories."""
import json
import pathlib
import sys
import tarfile

archive, destination, version = sys.argv[1:]
root = pathlib.Path(destination).resolve()
with tarfile.open(archive, 'r:gz') as package:
    members = package.getmembers()
    if sum(member.size for member in members) > 512 * 1024 * 1024:
        raise ValueError('Package is too large')
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir()):
            raise ValueError('Package contains an unsafe entry')
    package.extractall(root, members=members, filter='data')
manifest = json.loads((root / 'release.json').read_text())
if manifest['version'] != version or manifest['platform'] != 'linux-x64':
    raise ValueError('Package version/platform does not match')
for name in ['MultiTokenMonitor.dll', 'MultiTokenMonitor.runtimeconfig.json', 'wwwroot/index.html']:
    if not (root / name).is_file():
        raise ValueError('Package is incomplete')
print('Validated:', manifest['version'], manifest['revision'])
