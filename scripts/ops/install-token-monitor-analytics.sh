#!/usr/bin/env bash
set -euo pipefail
umask 027
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROD_ROOT=/home/mediaserver/ManageMediaServer
VERSION=${1:?Usage: install-token-monitor-analytics.sh VERSION ARCHIVE CHECKSUM}
ARCHIVE=$(realpath "${2:?Archive required}")
CHECKSUM=$(realpath "${3:?Checksum file required}")
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ -f "$ARCHIVE" && -f "$CHECKSUM" ]]
mountpoint -q /mnt/backup || { echo 'ERROR: /mnt/backup is not mounted' >&2; exit 1; }
getent passwd mediaserver >/dev/null
for file in scripts/update.sh scripts/validate-package.py scripts/firewall.sh scripts/healthcheck.sh \
    systemd/token-monitor-analytics.service systemd/token-monitor-analytics-http.service \
    systemd/token-monitor-analytics-firewall.service; do
    [[ -f "$REPO_ROOT/token-monitor-analytics/$file" ]] || { echo "Missing: $file" >&2; exit 1; }
done
expected=$(awk 'NR == 1 {print $1}' "$CHECKSUM")
[[ "$expected" =~ ^[0-9a-f]{64}$ && $(sha256sum "$ARCHIVE" | cut -d ' ' -f 1) == "$expected" ]] \
    || { echo 'ERROR: checksum mismatch' >&2; exit 1; }
VERIFY_DIR=$(mktemp -d)
trap 'rm -rf "$VERIFY_DIR"' EXIT
python3 "$REPO_ROOT/token-monitor-analytics/scripts/validate-package.py" "$ARCHIVE" "$VERIFY_DIR/app" "$VERSION"
rm -rf "$VERIFY_DIR"
trap - EXIT
LAN_IP=$(ip -4 -o addr show dev enp1s0 | awk '{print $4}' | cut -d/ -f1)
TAILSCALE_IP=$(tailscale ip -4)
[[ "$LAN_IP" == 192.168.0.23 && "$TAILSCALE_IP" == 100.69.11.74 ]] \
    || { echo 'ERROR: host addresses changed; review network configuration' >&2; exit 1; }
if ! systemctl is-active --quiet token-monitor-analytics-http.service; then
    [[ -z $(ss -H -ltn 'sport = :3000') ]] || { echo 'ERROR: TCP 3000 is already in use' >&2; exit 1; }
fi
if ! systemctl is-active --quiet token-monitor-analytics.service; then
    [[ -z $(ss -H -ltn 'sport = :13000') ]] || { echo 'ERROR: internal TCP 13000 is already in use' >&2; exit 1; }
fi

BACKUP=/mnt/backup/token-monitor-analytics/install-$(date -u +%Y%m%dT%H%M%S)
install -d -m 0750 "$BACKUP"
for path in /etc/token-monitor-analytics "$PROD_ROOT/token-monitor-analytics"; do
    [[ ! -e "$path" ]] || cp -a "$path" "$BACKUP/"
done
for name in media-daily-maintenance.sh media-health-check.sh; do
    [[ ! -f "$PROD_ROOT/scripts/ops/$name" ]] || cp -a "$PROD_ROOT/scripts/ops/$name" "$BACKUP/"
done
[[ ! -f "$PROD_ROOT/config/env/media-daily-maintenance.env" ]] \
    || cp -a "$PROD_ROOT/config/env/media-daily-maintenance.env" "$BACKUP/"
for name in token-monitor-analytics token-monitor-analytics-http token-monitor-analytics-firewall; do
    [[ ! -f "/etc/systemd/system/$name.service" ]] || cp -a "/etc/systemd/system/$name.service" "$BACKUP/"
done
echo "Previous deployment configuration backed up to: $BACKUP"

# Prevent installation from unexpectedly opening nginx's default port 80.
MASKED=false
if [[ $(systemctl show nginx.service -p LoadState --value) == not-found ]]; then
    systemctl mask nginx.service
    MASKED=true
fi
unmask_nginx() { [[ $MASKED == false ]] || systemctl unmask nginx.service; }
trap unmask_nginx EXIT
apt-get update
apt-get install -y aspnetcore-runtime-10.0 nginx-light iptables curl jq python3
if [[ $MASKED == true ]]; then
    systemctl unmask nginx.service
    systemctl disable nginx.service
    MASKED=false
fi

install -d -m 0755 /opt/token-monitor-analytics/releases "$PROD_ROOT/token-monitor-analytics"
cp -a "$REPO_ROOT/token-monitor-analytics/." "$PROD_ROOT/token-monitor-analytics/"
chown -R root:root "$PROD_ROOT/token-monitor-analytics"
find "$PROD_ROOT/token-monitor-analytics/scripts" -name '*.sh' -exec chmod 0755 {} +
install -d -m 0750 -o root -g mediaserver /etc/token-monitor-analytics
install -d -m 0750 -o mediaserver -g mediaserver /mnt/data/token-monitor-analytics
install -d -m 0750 -o root -g mediaserver /mnt/backup/token-monitor-analytics
if [[ ! -f /etc/token-monitor-analytics/deploy.env ]]; then
    install -m 0640 -o root -g mediaserver "$REPO_ROOT/config/env/token-monitor-analytics.env.example" /etc/token-monitor-analytics/deploy.env
fi
if [[ ! -f /mnt/data/token-monitor-analytics/hubs.local.json ]]; then
    # Existing production Hub credentials stay on this host and are never printed.
    source "$PROD_ROOT/config/env/token-monitor-common.env"
    : "${TOKEN_MONITOR_SECRET:?Missing existing Hub secret}"
    export TOKEN_MONITOR_SECRET
    python3 - <<'PY'
import json, os, pathlib
hubs = [dict(id=name, name=label, url=f'http://127.0.0.1:{port}', token=os.environ['TOKEN_MONITOR_SECRET'])
        for name, label, port in [('private', 'Private', 17321), ('work', 'Work', 17322)]]
pathlib.Path('/mnt/data/token-monitor-analytics/hubs.local.json').write_text(json.dumps({'hubs': hubs}, indent=2) + '\n')
PY
    unset TOKEN_MONITOR_SECRET
    chown mediaserver:mediaserver /mnt/data/token-monitor-analytics/hubs.local.json
    chmod 0600 /mnt/data/token-monitor-analytics/hubs.local.json
fi
cat > /etc/token-monitor-analytics/app.env <<'ENV'
HOST=127.0.0.1
PORT=13000
DB_PATH=/mnt/data/token-monitor-analytics/app.sqlite
HUB_CONFIG_PATH=/mnt/data/token-monitor-analytics/hubs.local.json
ASPNETCORE_ENVIRONMENT=Production
Logging__LogLevel__Default=Information
ENV
cat > /etc/token-monitor-analytics/network.env <<'ENV'
LAN_CIDR=192.168.0.0/24
LAN_IP=192.168.0.23
TAILSCALE_IP=100.69.11.74
ENV
cat > /etc/token-monitor-analytics/nginx.conf <<'NGINX'
worker_processes 1;
pid /run/token-monitor-analytics-http/nginx.pid;
error_log stderr;
events { worker_connections 256; }
http {
    access_log off;
    client_body_temp_path /run/token-monitor-analytics-http/client;
    proxy_temp_path /run/token-monitor-analytics-http/proxy;
    fastcgi_temp_path /run/token-monitor-analytics-http/fastcgi;
    uwsgi_temp_path /run/token-monitor-analytics-http/uwsgi;
    scgi_temp_path /run/token-monitor-analytics-http/scgi;
    server {
        listen 127.0.0.1:3000 default_server;
        listen 192.168.0.23:3000 default_server;
        listen 100.69.11.74:3000 default_server;
        server_name _;
        return 400;
    }
    server {
        listen 127.0.0.1:3000;
        listen 192.168.0.23:3000;
        listen 100.69.11.74:3000;
        server_name localhost 127.0.0.1 192.168.0.23 100.69.11.74 home-ubuntu home-ubuntu.tail1bf795.ts.net;
        location / {
            proxy_pass http://127.0.0.1:13000;
            proxy_http_version 1.1;
            proxy_set_header Host localhost;
            proxy_set_header Connection "";
            proxy_buffering off;
            proxy_read_timeout 3600s;
        }
    }
}
NGINX
chown root:mediaserver /etc/token-monitor-analytics/*
chmod 0640 /etc/token-monitor-analytics/*
for unit in "$PROD_ROOT/token-monitor-analytics/systemd/"*.service; do
    install -m 0644 "$unit" "/etc/systemd/system/$(basename "$unit")"
done
systemctl daemon-reload
"$PROD_ROOT/token-monitor-analytics/scripts/update.sh" --version "$VERSION" --archive "$ARCHIVE" --sha256-file "$CHECKSUM"
systemctl enable token-monitor-analytics.service token-monitor-analytics-firewall.service token-monitor-analytics-http.service
systemctl restart token-monitor-analytics-firewall.service
systemctl restart token-monitor-analytics-http.service
"$PROD_ROOT/token-monitor-analytics/scripts/healthcheck.sh"
for address in "$LAN_IP" "$TAILSCALE_IP"; do
    curl -fsS --max-time 10 "http://$address:3000/api/overview" | jq -e 'type == "object"' >/dev/null
    echo "OK: http://$address:3000/"
done
synced=false
for _ in {1..30}; do
    if curl -fsS --max-time 5 http://127.0.0.1:3000/api/overview \
        | jq -e '.hubs | length > 0 and all(.[]; .connected and .receivedAt != null)' >/dev/null; then
        synced=true
        break
    fi
    sleep 2
done
[[ $synced == true ]] || { echo 'ERROR: application is running, but Hub synchronization has not completed; inspect journalctl -u token-monitor-analytics' >&2; exit 1; }
echo 'OK: all configured Hubs synchronized'

# Integrate only Analytics into existing maintenance; do not trigger media updates.
for name in media-daily-maintenance.sh media-health-check.sh; do
    install -m 0755 "$REPO_ROOT/scripts/ops/$name" "$PROD_ROOT/scripts/ops/$name"
done
python3 - <<'PY'
from pathlib import Path
path = Path('/home/mediaserver/ManageMediaServer/config/env/media-daily-maintenance.env')
text = path.read_text() if path.exists() else ''
lines = [line for line in text.splitlines() if not line.startswith('RUN_ANALYTICS_UPDATE=')]
path.write_text('\n'.join(lines + ['RUN_ANALYTICS_UPDATE=true']) + '\n')
PY
systemctl --no-pager --full status token-monitor-analytics.service token-monitor-analytics-http.service
echo 'Analytics installed. Manual updates: sudo /home/mediaserver/ManageMediaServer/token-monitor-analytics/scripts/update.sh --version vX.Y.Z'
