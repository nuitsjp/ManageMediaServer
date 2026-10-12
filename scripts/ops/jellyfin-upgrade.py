#!/usr/bin/env python3
"""Check an upgrade without printing account, library, or credential data."""
import argparse
import base64
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import time
import uuid
import xml.etree.ElementTree as ET

# Jellyfin v12.2 ScheduledTaskWorker uses Encoding.Unicode + MD5 + Guid.
TASK_NAME = "Emby.Server.Implementations.ScheduledTasks.Tasks.RefreshMediaLibraryTask"
TASK_ID = str(uuid.UUID(bytes_le=hashlib.md5(TASK_NAME.encode("utf-16le")).digest()))
SCAN_FILE = f"{TASK_ID}.js"
PLUGIN_URL = "https://repo.jellyfin.org/files/plugin/manifest.json"


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, default=str).encode()).hexdigest()


def snapshot(config):
    path = Path(config) / "data/jellyfin.db"
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=10) as db:
        if db.execute("PRAGMA quick_check").fetchone() != ("ok",):
            raise ValueError("database integrity check failed")
        users = sorted(digest(list(row)) for row in db.execute('SELECT Id, Password FROM Users'))
        media = sorted({digest(row[0]) for row in db.execute(
            "SELECT Path FROM BaseItems WHERE IsFolder=0 AND MediaType IN ('Video','Audio') AND Path LIKE '/media/%'")})
        progress = sorted({digest(list(row)) for row in db.execute(
            "SELECT u.UserId,b.Path,u.PlayCount,u.Played,u.IsFavorite,u.PlaybackPositionTicks "
            "FROM UserData u JOIN BaseItems b ON b.Id=u.ItemId "
            "WHERE b.Path LIKE '/media/%' AND "
            "(u.PlayCount>0 OR u.Played=1 OR u.IsFavorite=1 OR u.PlaybackPositionTicks>0)")})
    return {"users": users, "media": media, "progress": progress}


def verify_snapshot(before, after):
    if before["users"] != after["users"]:
        raise ValueError("existing accounts or authentication data changed")
    for key in ("media", "progress"):
        if not set(before[key]).issubset(after[key]):
            raise ValueError(f"existing {key} records are missing or changed")


def prepare_scan(config, state_file):
    config = Path(config)
    path = config / "config/ScheduledTasks" / SCAN_FILE
    if path.is_symlink():
        raise ValueError("unexpected scan configuration symlink")
    state = {"existed": path.exists(), "content": "", "mode": 0o644}
    if path.exists():
        raw = path.read_bytes()
        state.update(content=base64.b64encode(raw).decode(), mode=path.stat().st_mode & 0o777)
        triggers = json.loads(raw)
    else:
        triggers = [{"Type": "IntervalTrigger", "IntervalTicks": 12 * 3600 * 10_000_000}]
    if not isinstance(triggers, list) or any(not isinstance(item, dict) for item in triggers):
        raise ValueError("invalid scan schedule")
    # Save the original schedule before adding a one-time startup trigger.
    Path(state_file).write_text(json.dumps(state))
    if not any(item.get("Type", item.get("type")) in ("StartupTrigger", 3) for item in triggers):
        triggers.append({"Type": "StartupTrigger"})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(triggers))
    os.chmod(path, state["mode"])
    if os.geteuid() == 0:
        os.chown(path.parent, 1001, 1001)
        os.chown(path, 1001, 1001)
    system = config / "config/system.xml"
    tree = ET.parse(system)
    for entry in tree.getroot().findall("./PluginRepositories/*/Url"):
        if (entry.text or "").startswith(("https://repo.jellyfin.org/", "http://repo.jellyfin.org/")):
            entry.text = PLUGIN_URL
    tree.write(system, encoding="utf-8", xml_declaration=True)


def restore_scan(config, state_file):
    path = Path(config) / "config/ScheduledTasks" / SCAN_FILE
    state = json.loads(Path(state_file).read_text())
    if state["existed"]:
        path.write_bytes(base64.b64decode(state["content"]))
        os.chmod(path, state["mode"])
        if os.geteuid() == 0:
            os.chown(path, 1001, 1001)
    else:
        path.unlink(missing_ok=True)


def scan_result(config, since):
    path = Path(config) / "data/ScheduledTasks" / SCAN_FILE
    try:
        result = json.loads(path.read_text())
    except (OSError, ValueError):
        return False
    if not isinstance(result, dict) or "StartTimeUtc" not in result:
        return False
    started = datetime.fromisoformat(result["StartTimeUtc"].replace("Z", "+00:00"))
    if started.timestamp() < since or result.get("Key") != "RefreshLibrary":
        return False
    if result.get("Status") != "Completed":
        raise ValueError("post-upgrade library scan failed")
    if "EndTimeUtc" not in result:
        return False
    return True


def wait_scan(config, since, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if scan_result(config, since):
            print("OK: post-upgrade full library scan completed")
            return
        time.sleep(2)
    raise ValueError("library scan did not complete before timeout")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    save = commands.add_parser("snapshot")
    save.add_argument("config"); save.add_argument("output")
    verify = commands.add_parser("verify")
    verify.add_argument("baseline"); verify.add_argument("config")
    for name in ("prepare-scan", "restore-scan"):
        command = commands.add_parser(name)
        command.add_argument("config"); command.add_argument("state")
    wait = commands.add_parser("wait-scan")
    wait.add_argument("config"); wait.add_argument("since", type=float)
    wait.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            info = snapshot(args.config)
            Path(args.output).write_text(json.dumps(info))
            print(f"OK: database integrity; accounts={len(info['users'])}, media={len(info['media'])}")
        elif args.command == "verify":
            before = json.loads(Path(args.baseline).read_text())
            verify_snapshot(before, snapshot(args.config))
            print("OK: database integrity, accounts, media, and viewing state preserved")
        elif args.command == "prepare-scan":
            prepare_scan(args.config, args.state)
        elif args.command == "restore-scan":
            restore_scan(args.config, args.state)
        else:
            wait_scan(args.config, args.since, args.timeout)
    except (OSError, ValueError, KeyError, sqlite3.Error, ET.ParseError):
        # Avoid dumping SQL values, user names, library paths, or server responses.
        print("ERROR: Jellyfin upgrade data or scan validation failed; inspect protected backup logs", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
