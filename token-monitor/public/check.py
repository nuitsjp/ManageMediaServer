#!/usr/bin/env python3
"""Check public transport and authentication without reading credentials."""
import argparse
import json
import pathlib
import urllib.error
import urllib.parse
import urllib.request


def request(base, path, headers=None):
    req = urllib.request.Request(base.rstrip("/") + path, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, response.headers, response.read(1024 * 1024)
    except urllib.error.HTTPError as error:
        status, headers = error.code, error.headers
        error.close()
        return status, headers, b""


def check(base):
    parsed = urllib.parse.urlsplit(base)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("The endpoint must not contain credentials or query parameters")
    if parsed.scheme != "https" and not (
        parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
    ):
        raise ValueError("The public endpoint must use HTTPS")
    status, headers, body = request(base, "/api/health")
    if status != 200:
        raise ValueError(f"Public health returned HTTP {status}")
    health = json.loads(body)
    if health.get("ok") is not True or health.get("role") != "hub" or health.get("secretRequired") is not True:
        raise ValueError("Public Hub is unhealthy or its own authentication is disabled")
    if headers.get("X-Content-Type-Options") != "nosniff" or "max-age=" not in headers.get("Strict-Transport-Security", ""):
        raise ValueError("Public proxy security headers are missing")
    for label, auth in [("anonymous", {}), ("invalid token", {"Authorization": "Bearer public-health-invalid-token"})]:
        status, _, _ = request(base, "/api/devices", auth)
        if status != 401:
            raise ValueError(f"Public data did not reject {label}: HTTP {status}")
    print("OK: public HTTPS/proxy, Hub health, and anonymous/invalid-token rejection")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url")
    args = parser.parse_args()
    try:
        url = args.url or json.loads(pathlib.Path("/etc/token-monitor-public/endpoint.json").read_text())["url"]
        check(url)
    except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
        # Never print exception bodies/URLs supplied by a backend.
        raise SystemExit(f"ERROR: public Hub check failed ({type(error).__name__}): {error if isinstance(error, ValueError) else 'transport/configuration unavailable'}")


if __name__ == "__main__":
    main()
