#!/usr/bin/env bash
# First installation only. Existing HA and media services are not restarted.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
REUSE_CREDENTIALS=
if [[ $# == 2 && $1 == --reuse-credentials ]]; then REUSE_CREDENTIALS=$2;
elif (( $# != 0 )); then echo 'Usage: install-smarthome-mqtt.sh [--reuse-credentials PRIVATE_BACKUP]' >&2; exit 2; fi
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROD=/home/mediaserver/ManageMediaServer
DATA=/mnt/data/smarthome/mosquitto
PRIVATE=/etc/manage-smarthome/mqtt-private
CLIENTS=/etc/manage-smarthome/mqtt-clients.json
LIB=/usr/local/libexec/manage-smarthome/apply-smarthome-mqtt-firewall.sh
COMPOSE=$PROD/docker/mosquitto/docker-compose.yml
IMAGE=eclipse-mosquitto:2.1.2-alpine@sha256:22075095e8790eec5592ff3c213b1974cd51aa458275af2f8b0595af4c385df2
fail() { echo "ERROR: $*" >&2; exit 1; }
hash_password_file() {
    docker run --rm --network none --read-only --tmpfs /tmp:rw,noexec,nosuid,size=8m,mode=1777 --cap-drop ALL --user 0:0 \
        -v "$1:/work" --entrypoint mosquitto_passwd "$IMAGE" -U /work/passwords
}
for tool in docker openssl python3 iptables ip6tables flock install logger mountpoint; do command -v "$tool" >/dev/null; done
[[ -f /etc/manage-smarthome/firewall.env && ! -L /etc/manage-smarthome/firewall.env ]] || fail 'Existing smart home firewall configuration is required.'
for path in /mnt/data/smarthome /mnt/backup/smarthome /etc/manage-smarthome /usr/local/libexec/manage-smarthome; do
    [[ -d $path && ! -L $path && $(stat -c %u "$path") == 0 && -z $(find "$path" -maxdepth 0 -perm /022 -print) ]] || fail "Unprotected directory: $path"
done
for path in "$DATA" "$PRIVATE" "$CLIENTS" "$LIB"; do [[ ! -e $path && ! -L $path ]] || fail "Existing target: $path"; done
for unit in smarthome-mqtt.service smarthome-mqtt-firewall.service; do
    [[ $(systemctl show "$unit" -p LoadState --value) == not-found ]] || fail "Existing unit: $unit"
done
[[ -z $(ss -H -ltn '( sport = :1883 or sport = :8883 )') ]] || fail 'MQTT ports are already in use.'
[[ -z $(docker ps -aq --filter 'name=^/smarthome-mqtt$') ]] || fail 'MQTT container already exists.'
mountpoint -q /mnt/backup || fail 'Backup disk is not mounted.'
(( $(df --output=avail -k /mnt/backup | tail -1) > 131072 )) || fail 'Insufficient backup space.'
python3 "$REPO/scripts/ops/prepare-smarthome-runtime.py"
exec 8<>/run/manage-smarthome/install.lock; flock -n 8 || fail 'Smart home maintenance is running.'
exec 9<>/run/manage-media-maintenance/daily.lock; flock -n 9 || fail 'Daily media maintenance is running.'
BACKUP=$(mktemp -d /mnt/backup/smarthome/mqtt-install-XXXXXXXX)
cp -a "$0" "$BACKUP/installer.sh"
docker ps -q | sort > "$BACKUP/containers-before.txt"
STAGE=prepare
DEPLOYED=false
finish() {
    local result=$? rollback=false
    trap - EXIT
    if (( result != 0 )); then
        local stopped=true remaining
        if [[ $DEPLOYED == true ]]; then
            systemctl disable --now smarthome-mqtt.service smarthome-mqtt-firewall.service || rollback=true
            docker compose -f "$COMPOSE" down || rollback=true
            if remaining=$(docker ps -q --filter 'name=^/smarthome-mqtt$') && [[ -z $remaining ]]; then
                bash "$REPO/scripts/ops/apply-smarthome-mqtt-firewall.sh" remove || rollback=true
                while IFS= read -r path; do
                    if [[ -f $BACKUP/files$path ]]; then cp -a "$BACKUP/files$path" "$path" || rollback=true;
                    else rm -f -- "$path" || rollback=true; fi
                done < "$BACKUP/targets.txt"
                systemctl daemon-reload || rollback=true
            else
                stopped=false; rollback=true
                echo 'Cannot confirm the broker stopped; retaining its data, files and firewall.' >&2
            fi
        fi
        if [[ $stopped == true ]]; then
            for path in "$DATA" "$PRIVATE" "$CLIENTS"; do
                if [[ -e $path ]]; then mv "$path" "$BACKUP/$(basename "$path")" || rollback=true; fi
            done
        fi
    fi
    printf 'stage=%s\nexit_status=%s\nrollback_failed=%s\nbackup=%s\n' "$STAGE" "$result" "$rollback" "$BACKUP" | tee "$BACKUP/result.txt"
    logger -t manage-smarthome "mqtt-install stage=$STAGE exit_status=$result rollback_failed=$rollback backup=$BACKUP"
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
STAGE=image-pull
docker pull --platform linux/amd64 "$IMAGE"
STAGE=password-tool-check
PASSWORD_TEST=$(mktemp -d "$BACKUP/password-tool-XXXXXXXX")
printf 'test:not-a-real-password\n' > "$PASSWORD_TEST/passwords"
hash_password_file "$PASSWORD_TEST"
python3 - "$PASSWORD_TEST/passwords" <<'PY'
from pathlib import Path
import sys
data=Path(sys.argv[1]).read_text()
if not data.startswith('test:$') or 'not-a-real-password' in data:
    raise SystemExit('Container password conversion self-test failed')
PY
rm -r -- "$PASSWORD_TEST"
STAGE=credentials
install -d -m 0700 -o root -g root "$PRIVATE" "$DATA"
install -d -m 0750 -o root -g 1883 "$DATA/config"
install -d -m 0700 -o 1883 -g 1883 "$DATA/data"
if [[ -n $REUSE_CREDENTIALS ]]; then
    python3 - "$REPO/scripts/ops" "$REUSE_CREDENTIALS" "$CLIENTS" <<'PY'
import json,os,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from smarthome_mqtt import private_json
source=Path(sys.argv[2])
if not str(source).startswith('/mnt/backup/smarthome/'):
    raise SystemExit('Use the private smart home installation backup')
data=private_json(source)
if data.get('host')!='192.168.0.23' or set(data.get('passwords',{}))!={'homeassistant','nanoc6','smarthome-check'}:
    raise SystemExit('Unexpected saved MQTT credentials')
if any(not isinstance(p,str) or len(p)<16 or '\n' in p or '\r' in p for p in data['passwords'].values()):
    raise SystemExit('Invalid saved MQTT credentials')
fd=os.open(sys.argv[3],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w') as stream:json.dump(data,stream)
print('Reused the previously chosen MQTT credentials; no password input is needed.')
PY
else
    python3 "$REPO/scripts/ops/smarthome_mqtt.py" init --credentials "$CLIENTS"
fi
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 -subj '/CN=Manage Smart Home MQTT CA' \
    -keyout "$PRIVATE/ca.key" -out "$DATA/config/ca.crt" > "$BACKUP/ca-generation.log" 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=192.168.0.23' \
    -keyout "$DATA/config/server.key" -out "$PRIVATE/server.csr" > "$BACKUP/server-generation.log" 2>&1
printf 'subjectAltName=IP:192.168.0.23,DNS:192.168.0.23,IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n' > "$PRIVATE/server.ext"
openssl x509 -req -sha256 -days 825 -in "$PRIVATE/server.csr" -CA "$DATA/config/ca.crt" -CAkey "$PRIVATE/ca.key" \
    -CAcreateserial -CAserial "$PRIVATE/ca.srl" -extfile "$PRIVATE/server.ext" -out "$DATA/config/server.crt" > "$BACKUP/server-signing.log" 2>&1
python3 - "$CLIENTS" "$DATA/config/passwords" <<'PY'
import json,os,sys
config=json.load(open(sys.argv[1]))
fd=os.open(sys.argv[2],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as stream:
    for user,password in config['passwords'].items(): stream.write(user+':'+password+'\n')
PY
hash_password_file "$DATA/config"
install -m 0640 -o root -g 1883 "$REPO/config/mosquitto/mosquitto.conf" "$DATA/config/mosquitto.conf"
install -m 0640 -o root -g 1883 "$REPO/config/mosquitto/acl" "$DATA/config/acl"
chown root:1883 "$DATA/config/"{passwords,server.key,server.crt,ca.crt}
chmod 0640 "$DATA/config/"{passwords,server.key,server.crt,ca.crt}
STAGE=deploy
install -d -m 0700 "$BACKUP/files"
# Snapshot every managed destination before deploy; restore only after proven stop.
python3 - "$REPO" "$PROD" "$LIB" "$BACKUP" <<'PY2'
import sys,subprocess
from pathlib import Path
repo,prod,lib,backup=map(Path,sys.argv[1:])
text=(repo/'scripts/ops/deploy-managed-files.sh').read_text().split('if [[ "$MQTT_ONLY" == true ]]; then',1)[1]
block=text.split('for source in ',1)[1].split('; do',1)[0].replace('\\','')
sources=block.split()
targets=[prod/s for s in sources]+[Path('/etc/systemd/system')/s for s in ('smarthome-mqtt.service','smarthome-mqtt-firewall.service')]+[lib]
for path in targets:
    if path.is_symlink() or (path.exists() and not path.is_file()): raise SystemExit('Unexpected managed target')
    if path.is_file():
        subprocess.run(['cp','-a','--parents',str(path),str(backup/'files')],check=True)
(backup/'targets.txt').write_text(''.join(str(p)+'\n' for p in targets))
PY2
DEPLOYED=true
PROD_ROOT="$PROD" BACKUP_PARENT="$BACKUP/managed-files" bash "$REPO/scripts/ops/deploy-managed-files.sh" --mqtt-only
install -m 0755 -o root -g root "$REPO/scripts/ops/apply-smarthome-mqtt-firewall.sh" "$LIB"
STAGE=start
systemctl daemon-reload
systemctl enable --now smarthome-mqtt-firewall.service
systemctl enable --now smarthome-mqtt.service
STAGE=verify
for ((attempt=0; attempt<30; attempt++)); do
    if python3 "$REPO/scripts/ops/smarthome_mqtt.py" check > "$BACKUP/mqtt-check.txt" 2>&1; then break; fi
    sleep 2
done
python3 "$REPO/scripts/ops/smarthome_mqtt.py" check
while IFS= read -r container; do docker inspect -f '{{.State.Running}}' "$container" | grep -qx true || fail 'An existing container stopped.'; done < "$BACKUP/containers-before.txt"
systemctl is-active --quiet homeassistant.service
bash "$LIB" status > "$BACKUP/firewall.txt"
STAGE=complete
echo 'MQTT broker installed. HA: broker=127.0.0.1 port=1883 username=homeassistant; use the MQTT password chosen above.'
