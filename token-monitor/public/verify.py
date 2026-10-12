#!/usr/bin/env python3
"""Verify authenticated compatibility with a running Hub; omit all data/secrets."""
import argparse
import json
import subprocess
import urllib.error
import urllib.request

from check import check


def verify(base):
    check(base)
    result = subprocess.run(
        ["docker", "inspect", "--format", "{{json .Config.Env}}", "token-monitor-hub-work"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise ValueError("Cannot inspect work Hub credentials")
    env = dict(item.split("=", 1) for item in json.loads(result.stdout) if "=" in item)
    secret = env.get("TOKEN_MONITOR_SECRET", "").strip()
    for path, headers in [
        ("/api/devices", {"Authorization": "Bearer " + secret}),
        ("/api/stats", {"X-Token-Monitor-Secret": secret}),
        ("/api/stats/stream", {"Authorization": "Bearer " + secret, "X-Token-Monitor-Stream": "2"}),
    ]:
        request = urllib.request.Request(base.rstrip("/") + path, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                if response.status != 200:
                    raise ValueError("Authenticated request was rejected")
                if path.endswith("/stream"):
                    if response.headers.get_content_type() != "text/event-stream" or not response.readline(65536).startswith(b"event:"):
                        raise ValueError("SSE did not deliver its first event")
                else:
                    response.read(1024 * 1024)
        except urllib.error.HTTPError as error:
            raise ValueError(f"Authenticated compatibility check returned HTTP {error.code}") from None
    print("OK: Bearer/X-token authentication, data reads, and SSE compatibility; data omitted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    args = parser.parse_args()
    try:
        verify(args.url)
    except (OSError, ValueError, urllib.error.URLError):
        raise SystemExit("ERROR: authenticated public Hub verification failed; data/secrets omitted")


if __name__ == "__main__":
    main()
