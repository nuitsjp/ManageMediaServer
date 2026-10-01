#!/usr/bin/env bash
set -euo pipefail
curl -fsS --max-time 10 http://127.0.0.1:3000/api/overview | jq -e 'type == "object"' >/dev/null
html=$(curl -fsS --max-time 10 -H 'Accept: text/html' http://127.0.0.1:3000/)
[[ "$html" == *'<html'* ]]
echo 'OK: Token Monitor Analytics API and UI'
