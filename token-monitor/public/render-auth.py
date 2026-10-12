#!/usr/bin/env python3
"""Render a private nginx authentication map without executing an env file."""
import argparse
import json
import os
import pathlib
import re
import subprocess
import tempfile


def auth_config(secret):
    # Restrict the syntax so secret text cannot become nginx directives/regexes.
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", secret) or secret == "replace-with-openssl-rand-hex-32":
        raise ValueError("The running work Hub must have a strong URL-safe secret (32-256 characters)")
    return (
        "# Secret-bearing file: root-owned, mode 0640, service group only.\n"
        "map $http_authorization $public_bearer_ok {\n"
        "    default 0;\n"
        f'    "~^(?i:Bearer)[ ]+{secret}[ ]*$" 1;\n'
        "}\n"
        "map $http_x_token_monitor_secret $public_header_ok {\n"
        "    default 0;\n"
        f'    "{secret}" 1;\n'
        "}\n"
        # Match the Hub's precedence: a Bearer header takes priority over X-token.
        "map $http_authorization $public_has_bearer {\n"
        "    default 0;\n"
        '    "~*^Bearer[ ]" 1;\n'
        "}\n"
        'map "$public_has_bearer:$public_bearer_ok:$public_header_ok" $public_auth_ok {\n'
        "    default 0;\n"
        '    "1:1:0" 1;\n'
        '    "1:1:1" 1;\n'
        '    "0:0:1" 1;\n'
        "}\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run with root privileges")
    result = subprocess.run(
        ["docker", "inspect", "--format", "{{json .Config.Env}}", "token-monitor-hub-work"],
        text=True, capture_output=True, check=False,
    )
    if result.returncode != 0:
        raise SystemExit("Cannot inspect the running work Hub")
    env = dict(item.split("=", 1) for item in json.loads(result.stdout) if "=" in item)
    text = auth_config(env.get("TOKEN_MONITOR_SECRET", "").strip())
    descriptor, temporary = tempfile.mkstemp(prefix=".auth.", dir=args.output.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(text)
        os.chmod(temporary, 0o600)
        os.replace(temporary, args.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print("Authentication map generated; secret value omitted.")


if __name__ == "__main__":
    main()
