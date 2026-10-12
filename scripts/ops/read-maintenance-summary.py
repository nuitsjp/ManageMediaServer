#!/usr/bin/env python3
"""Validate an untrusted child result and emit NUL-separated names and values."""
import json
import os
import stat
import sys

FIELDS = {
    "media-backup": "MEDIA_BACKUP_STATUS MEDIA_BACKUP_MESSAGE MEDIA_BACKUP_TARGETS MEDIA_BACKUP_DRY_RUN MEDIA_BACKUP_LOG_FILE",
    "media-app-update": "MEDIA_APP_UPDATE_STATUS MEDIA_APP_UPDATE_MESSAGE MEDIA_APP_UPDATED_CONTAINERS MEDIA_APP_MAJOR_UPDATES MEDIA_APP_LATEST_VERSIONS MEDIA_APP_DRY_RUN MEDIA_APP_CHECK_ONLY MEDIA_APP_LOG_FILE",
    "token-monitor-update": "TOKEN_MONITOR_UPDATE_STATUS TOKEN_MONITOR_CURRENT_VERSION TOKEN_MONITOR_LATEST_VERSION TOKEN_MONITOR_UPDATED_VERSION TOKEN_MONITOR_UPDATE_LOG_FILE",
    "analytics-update": "ANALYTICS_UPDATE_STATUS ANALYTICS_CURRENT_VERSION ANALYTICS_TARGET_VERSION",
    "rclone-media-sync": "RCLONE_SYNC_STATUS RCLONE_SYNC_MESSAGE RCLONE_IMAGE_COPY_STATUS RCLONE_VIDEO_COPY_STATUS RCLONE_BACKUP_STATUS RCLONE_VERIFIED_COUNT RCLONE_DELETED_COUNT RCLONE_SKIPPED_VIDEO_COUNT RCLONE_DRY_RUN RCLONE_NO_DELETE RCLONE_LOG_FILE RCLONE_VERIFIED_FILE RCLONE_DRY_RUN_LOG",
    "os-update": "MEDIA_OS_UPDATE_STATUS MEDIA_OS_UPDATE_MESSAGE MEDIA_OS_APT_UPGRADED_PACKAGES MEDIA_OS_APT_UPGRADED_COUNT MEDIA_OS_SNAP_REFRESHED_PACKAGES MEDIA_OS_SNAP_REFRESHED_COUNT MEDIA_OS_AUTOREMOVE_STATUS MEDIA_OS_REBOOT_REQUIRED MEDIA_OS_REBOOT_REQUIRED_PACKAGES MEDIA_OS_DRY_RUN MEDIA_OS_CHECK_ONLY MEDIA_OS_LOG_FILE",
}
MAX_BYTES = 65536
STATUSES = {
    "media-backup": {"succeeded", "failed"},
    "media-app-update": {"succeeded", "failed", "major-update-detected", "updated"},
    "token-monitor-update": {"succeeded", "failed", "update_available", "updated"},
    "analytics-update": {"failed", "no_release", "current", "update_available", "validated", "updated"},
    "rclone-media-sync": {"succeeded", "failed"},
    "os-update": {"succeeded", "failed"},
}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def read_summary(step, path):
    allowed = FIELDS[step].split()
    # Do not follow a substituted symlink or block opening a named pipe.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES:
            raise ValueError("result is not a bounded regular file")
        raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("result is too large")
    result = json.loads(raw, object_pairs_hook=unique_object)
    if not isinstance(result, dict) or not result.get(allowed[0]):
        raise ValueError("missing status")
    if any(key not in allowed or not isinstance(value, str) or "\0" in value
           for key, value in result.items()):
        raise ValueError("unexpected field or value")
    if result[allowed[0]] not in STATUSES[step]:
        raise ValueError("unexpected status")
    # Validate encoding before writing any output; Bash cannot preserve NULs.
    return b"".join(key.encode("ascii") + b"\0" + value.encode("utf-8") + b"\0"
                    for key, value in result.items())


def main():
    try:
        if len(sys.argv) != 3:
            raise ValueError("expected step and result path")
        output = read_summary(sys.argv[1], sys.argv[2])
    except (OSError, ValueError, KeyError, UnicodeError, RecursionError):
        # Never print the untrusted contents, which may contain credentials.
        print("Invalid or missing maintenance result", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
