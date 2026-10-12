#!/usr/bin/env python3
"""Copy literal env settings into the protected root configuration directory."""
import os
from pathlib import Path
import re
import shlex
import sys

KEYS = {
    "media-daily-maintenance.env": "PROD_ROOT LOG_DIR LOG_FILE LOCK_FILE CHILD_USER LAST_SUCCESS_FILE RUN_MEDIA_BACKUP RUN_MEDIA_APP_UPDATE RUN_TOKEN_MONITOR_UPDATE RUN_ANALYTICS_UPDATE RUN_RCLONE_SYNC RUN_OS_UPDATE RCLONE_SYNC_NO_DELETE AUTO_REBOOT AUTO_REBOOT_DELAY_MINUTES MEDIA_BACKUP_SCRIPT MEDIA_APP_UPDATE_SCRIPT TOKEN_MONITOR_UPDATE_SCRIPT RCLONE_MEDIA_SYNC_SCRIPT MEDIA_OS_UPDATE_SCRIPT",
    "media-os-update.env": "LOG_DIR LOG_FILE LOCK_FILE ROOT_MIN_FREE_KIB DATA_MIN_FREE_KIB BACKUP_MIN_FREE_KIB BACKUP_ROOT RUN_APT_UPDATE RUN_APT_UPGRADE APT_UPGRADE_COMMAND RUN_APT_AUTOREMOVE RUN_SNAP_REFRESH APT_LOCK_TIMEOUT_SECONDS",
    "notification.env": "NOTIFICATION_ENABLED DISCORD_WEBHOOK_URL",
}
OVERRIDES = {
    "media-daily-maintenance.env": {
        "PROD_ROOT": "/home/mediaserver/ManageMediaServer",
        "CHILD_USER": "mediaserver",
        "LOG_DIR": "/var/log/manage-media-maintenance/daily",
        "LOG_FILE": "/var/log/manage-media-maintenance/daily/media-daily-maintenance.log",
        "LOCK_FILE": "/run/manage-media-maintenance/daily.lock",
        "LAST_SUCCESS_FILE": "/var/lib/media-daily-maintenance/last-success",
        "MEDIA_OS_UPDATE_SCRIPT": "/usr/local/libexec/manage-media-maintenance/media-os-update.sh",
    },
    "media-os-update.env": {
        "LOG_DIR": "/var/log/manage-media-maintenance/os",
        "LOG_FILE": "/var/log/manage-media-maintenance/os/media-os-update.log",
        "LOCK_FILE": "/run/manage-media-maintenance/os.lock",
    },
    "notification.env": {},
}


def parse_env(text, name):
    result = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"\s*(?:export\s+)?([A-Z][A-Z0-9_]*)=(.*)", line)
        if not match or match[1] not in KEYS[name].split():
            raise ValueError("unsupported setting")
        # Interpret quoting only. Never expand variables or execute commands.
        words = shlex.split(match[2], comments=True, posix=True)
        if len(words) > 1:
            raise ValueError("setting must contain one literal value")
        result[match[1]] = words[0] if words else ""
    for key, value in result.items():
        if key.startswith("RUN_") or key in {"RCLONE_SYNC_NO_DELETE", "AUTO_REBOOT", "NOTIFICATION_ENABLED"}:
            if value not in {"true", "false"}:
                raise ValueError("invalid boolean setting")
        if key.endswith("_MIN_FREE_KIB") or key in {"AUTO_REBOOT_DELAY_MINUTES", "APT_LOCK_TIMEOUT_SECONDS"}:
            if not re.fullmatch(r"[0-9]{1,10}", value):
                raise ValueError("invalid numeric setting")
        if key == "APT_UPGRADE_COMMAND" and value not in {"upgrade", "full-upgrade", "dist-upgrade"}:
            raise ValueError("unsupported apt upgrade command")
    return result


def prepare(source, destination):
    source, destination = Path(source), Path(destination)
    # Parse every file before creating any output.
    configs = {}
    for name in KEYS:
        current = destination / name
        path = current if current.exists() else source / name
        values = parse_env(path.read_text(), name) if path.exists() else {}
        values.update(OVERRIDES[name])
        configs[name] = "".join(f"{key}={shlex.quote(value)}\n" for key, value in values.items())
    for name, content in configs.items():
        path = destination / name
        # The caller creates this root-owned directory; reject file symlinks.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
        os.chmod(path, 0o600)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("expected source and protected destination")
        prepare(*sys.argv[1:])
    except (OSError, ValueError):
        print("Cannot prepare protected maintenance settings; check literal env syntax and supported keys", file=sys.stderr)
        sys.exit(1)
