#!/usr/bin/env bash
# Install only the public Funnel protection; leave Hub data/runtime untouched.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID == 0 ]] || { echo 'Run this script with sudo.' >&2; exit 1; }
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROD_ROOT=/home/mediaserver/ManageMediaServer
SERVICE=token-monitor-public.service
PUBLIC_USER=token-monitor-public
CONFIG=/etc/token-monitor-public
for name in nginx python3 docker tailscale systemctl runuser curl; do
    command -v "$name" >/dev/null || { echo "Missing command: $name" >&2; exit 1; }
done
for file in token-monitor/public/nginx.conf token-monitor/public/render-auth.py \
    token-monitor/public/check.py token-monitor/public/verify.py token-monitor/public/logrotate.conf \
    token-monitor/systemd/token-monitor-public.service scripts/ops/media-health-check.sh \
    token-monitor/README.md README.md; do
    [[ -f "$REPO_ROOT/$file" ]] || { echo "Missing source file: $file" >&2; exit 1; }
done
[[ -f "$PROD_ROOT/config/env/token-monitor-common.env" ]]
mountpoint -q /mnt/backup || { echo '/mnt/backup must be mounted.' >&2; exit 1; }
exec 9>/run/lock/token-monitor-public-install.lock
flock -n 9 || { echo 'Another public proxy installation is running.' >&2; exit 1; }
BACKUP=$(mktemp -d /mnt/backup/token-monitor-public.XXXXXXXX)
TEMP=""
tailscale serve status --json > "$BACKUP/serve-before.json"
DOMAIN=$(python3 - "$BACKUP/serve-before.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
domains = [k.removesuffix(':443') for k,v in d.get('AllowFunnel',{}).items() if k.endswith(':443') and v]
if len(domains) != 1:
    raise SystemExit('Expected exactly one existing Funnel on TCP 443')
domain = domains[0]
proxy = d.get('Web',{}).get(domain+':443',{}).get('Handlers',{}).get('/',{}).get('Proxy')
if proxy not in ('http://127.0.0.1:17322','http://127.0.0.1:17422'):
    raise SystemExit('Existing TCP 443 does not target the work Hub/public proxy')
print(domain)
PY
)
ORIGINAL_PROXY=$(python3 - "$BACKUP/serve-before.json" "$DOMAIN" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['Web'][sys.argv[2]+':443']['Handlers']['/']['Proxy'])
PY
)
WAS_ACTIVE=false WAS_ENABLED=false CHANGED=false FUNNEL_CHANGED=false
systemctl is-active --quiet "$SERVICE" && WAS_ACTIVE=true
systemctl is-enabled --quiet "$SERVICE" 2>/dev/null && WAS_ENABLED=true
FILES=("$CONFIG" /etc/systemd/system/token-monitor-public.service \
    /etc/logrotate.d/token-monitor-public "$PROD_ROOT/token-monitor/public" \
    "$PROD_ROOT/token-monitor/systemd/token-monitor-public.service" \
    "$PROD_ROOT/scripts/ops/media-health-check.sh" "$PROD_ROOT/token-monitor/README.md" \
    "$PROD_ROOT/README.md")
finish() {
    local result=$?
    trap - EXIT
    if (( result != 0 )) && [[ $CHANGED == true ]]; then
        echo 'Installation failed; restoring the previous proxy/configuration.' >&2
        if [[ $FUNNEL_CHANGED == true ]]; then
            tailscale funnel --yes --bg --https=443 "$ORIGINAL_PROXY" || true
        fi
        systemctl stop "$SERVICE" || true
        for file in "${FILES[@]}"; do
            if [[ -e "$BACKUP/files$file" ]]; then
                rm -rf -- "$file"
                install -d -- "$(dirname "$file")"
                cp -a -- "$BACKUP/files$file" "$file"
            else
                rm -rf -- "$file"
            fi
        done
        systemctl daemon-reload
        if [[ $WAS_ENABLED == true ]]; then systemctl enable "$SERVICE"; else systemctl disable "$SERVICE" 2>/dev/null || true; fi
        [[ $WAS_ACTIVE != true ]] || systemctl start "$SERVICE"
    fi
    [[ -z "$TEMP" ]] || rm -rf -- "$TEMP"
    echo "Configuration backup: $BACKUP"
    exit "$result"
}
trap finish EXIT
TEMP=$(mktemp -d)
install -d -m 0700 "$BACKUP/files"
for file in "${FILES[@]}"; do
    [[ ! -e "$file" ]] || cp -a --parents -- "$file" "$BACKUP/files/"
done
# Reject weak credentials before installing or changing any service.
install -d "$TEMP/config"
python3 -B "$REPO_ROOT/token-monitor/public/render-auth.py" "$TEMP/config/auth.conf"
if ! id "$PUBLIC_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --user-group "$PUBLIC_USER"
fi
[[ "$(id -nG "$PUBLIC_USER")" == "$PUBLIC_USER" ]] || { echo 'Public proxy account must have only its own group.' >&2; exit 1; }
[[ "$(getent passwd "$PUBLIC_USER" | cut -d: -f7)" == /usr/sbin/nologin ]] || { echo 'Public proxy account must not permit login.' >&2; exit 1; }
CHANGED=true
install -d -m 0755 -o root -g root "$CONFIG" "$PROD_ROOT/token-monitor/public"
install -m 0644 -o root -g root "$REPO_ROOT/token-monitor/public/nginx.conf" "$CONFIG/nginx.conf"
install -m 0640 -o root -g "$PUBLIC_USER" "$TEMP/config/auth.conf" "$CONFIG/auth.conf"
python3 - "$CONFIG/endpoint.json" "$DOMAIN" <<'PY'
import json,os,sys
with open(sys.argv[1],'w') as f: json.dump({'url':'https://'+sys.argv[2]},f)
os.chmod(sys.argv[1],0o644)
PY
for file in nginx.conf render-auth.py check.py verify.py logrotate.conf; do
    install -m 0644 -o root -g root "$REPO_ROOT/token-monitor/public/$file" "$PROD_ROOT/token-monitor/public/$file"
done
install -m 0644 -D -o root -g root "$REPO_ROOT/token-monitor/systemd/token-monitor-public.service" \
    "$PROD_ROOT/token-monitor/systemd/token-monitor-public.service"
install -m 0644 -o root -g root "$REPO_ROOT/token-monitor/systemd/token-monitor-public.service" \
    /etc/systemd/system/token-monitor-public.service
install -m 0644 -o root -g root "$REPO_ROOT/token-monitor/public/logrotate.conf" /etc/logrotate.d/token-monitor-public
install -d -m 0700 -o "$PUBLIC_USER" -g "$PUBLIC_USER" /run/token-monitor-public
install -d -m 0750 -o "$PUBLIC_USER" -g "$PUBLIC_USER" /var/log/token-monitor-public
runuser -u "$PUBLIC_USER" -- nginx -t -c "$CONFIG/nginx.conf"
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
ready=false
for _ in {1..15}; do
    if curl -fsS --max-time 2 http://127.0.0.1:17422/api/health -o /dev/null; then ready=true; break; fi
    sleep 1
done
[[ $ready == true ]] || { echo 'Public proxy did not become ready.' >&2; exit 1; }
python3 -B "$PROD_ROOT/token-monitor/public/verify.py" --url http://127.0.0.1:17422
FUNNEL_CHANGED=true
tailscale funnel --yes --bg --https=443 http://127.0.0.1:17422
tailscale serve status --json > "$BACKUP/serve-after.json"
python3 - "$BACKUP/serve-before.json" "$BACKUP/serve-after.json" "$DOMAIN" <<'PY'
import json,sys
before=json.load(open(sys.argv[1])); after=json.load(open(sys.argv[2]))
before['Web'][sys.argv[3]+':443']['Handlers']['/']['Proxy']='http://127.0.0.1:17422'
if before != after: raise SystemExit('Unexpected change to another Tailscale endpoint')
print('OK: TCP 443 uses the protected proxy; all other endpoints match the snapshot.')
PY
python3 -B "$PROD_ROOT/token-monitor/public/verify.py" --url "https://$DOMAIN"
install -m 0755 -o root -g root "$REPO_ROOT/scripts/ops/media-health-check.sh" "$PROD_ROOT/scripts/ops/media-health-check.sh"
install -m 0644 -o root -g root "$REPO_ROOT/token-monitor/README.md" "$PROD_ROOT/token-monitor/README.md"
install -m 0644 -o root -g root "$REPO_ROOT/README.md" "$PROD_ROOT/README.md"
# No notification is sent during installation. The existing timer will use the
# new check and its normal failure/recovery notification behavior.
runuser -u mediaserver -- python3 -B "$PROD_ROOT/token-monitor/public/check.py"
systemctl show "$SERVICE" --property=ActiveState,User,Group,NoNewPrivileges,MemoryMax
echo 'OK: public Funnel protections installed and verified.'
