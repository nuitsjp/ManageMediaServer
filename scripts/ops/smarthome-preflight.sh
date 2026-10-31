#!/usr/bin/env bash
# 認証情報を読まず、ホストの状態だけを表示する。
set -euo pipefail
echo '=== Smart home preflight (read-only) ==='
date -Is
hostname
uname -r
free -h
uptime
df -h / /mnt/backup
findmnt -T /mnt/data -o TARGET,SOURCE,FSTYPE
findmnt -T /mnt/backup -o TARGET,SOURCE,FSTYPE
echo '=== Docker / Compose ==='
docker --version
docker compose version
echo '=== Existing services ==='
for name in docker immich jellyfin media-daily-maintenance.timer media-health-check.timer \
    token-monitor token-monitor-public token-monitor-analytics token-monitor-analytics-http; do
    printf '%s: ' "$name"
    systemctl is-active "$name" || true
done
echo '=== Bluetooth ==='
dpkg-query -W -f='${Package} ${Version} ${Status}\n' bluez 2>/dev/null || true
systemctl is-active bluetooth || true
ls -ld /sys/class/bluetooth/hci* 2>/dev/null || true
for path in /sys/class/rfkill/rfkill*; do
    [[ -d $path ]] || continue
    printf '%s: ' "$path"
    paste -sd ' ' "$path/name" "$path/type" "$path/soft" "$path/hard"
done
echo '=== Proposed paths ==='
for path in /home/mediaserver/ManageMediaServer/docker/homeassistant \
    /mnt/data/smarthome /mnt/backup/smarthome; do
    if [[ -e $path ]]; then ls -ld "$path"; else echo "Not present: $path"; fi
done
echo '=== HA/HomeKit/MQTT/ESPHome port conflicts ==='
ss -lntu | awk 'NR == 1 || $5 ~ /:(8123|21063|8883|6053|6052)$/ {print}'
if [[ $EUID == 0 ]]; then
    echo '=== Container health (no environment values) ==='
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    echo '=== Bluetooth controller ==='
    if command -v bluetoothctl >/dev/null; then timeout 15 bluetoothctl show || true; fi
else
    echo 'Container health / privileged firewall checks require the installation script.'
fi
