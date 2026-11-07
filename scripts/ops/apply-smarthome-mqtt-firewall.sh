#!/usr/bin/env bash
# Mosquitto uses host networking. Protect TLS and loopback plaintext separately.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CHAIN=MMS-MQTT

validate_lan() {
    [[ ${LAN_IFACE:-} =~ ^[a-zA-Z0-9_.:-]+$ && -d /sys/class/net/$LAN_IFACE ]] \
        || { echo 'Invalid LAN_IFACE.' >&2; exit 1; }
    python3 - "${LAN_CIDR:-}" <<'PY'
import ipaddress, sys
network = ipaddress.ip_network(sys.argv[1], strict=True)
if network.version != 4 or not network.is_private or network.prefixlen < 16:
    raise SystemExit('Use a private IPv4 LAN subnet, /16 or narrower.')
PY
}

remove_rules() {
    local tool=$1
        while "$tool" -w 10 -C INPUT -p tcp -m multiport --dports 1883,8883 -j "$CHAIN" 2>/dev/null; do
            "$tool" -w 10 -D INPUT -p tcp -m multiport --dports 1883,8883 -j "$CHAIN"
        done
        if "$tool" -w 10 -S "$CHAIN" >/dev/null 2>&1; then
            "$tool" -w 10 -F "$CHAIN"
            "$tool" -w 10 -X "$CHAIN"
        fi
}

apply_rules() {
    local tool=$1 count
    # 完成したチェーンだけを INPUT に接続。再適用時は先に DROP を置き、
    # 許可ルールの交換中も広く開放しない。
    "$tool" -w 10 -N "$CHAIN" 2>/dev/null || "$tool" -w 10 -S "$CHAIN" >/dev/null
    "$tool" -w 10 -I "$CHAIN" 1 -j DROP
    # 一時 DROP より後ろの既存ルールを削除する。
    count=$("$tool" -w 10 -S "$CHAIN" | awk '$1 == "-A" {n++} END {print n+0}')
    while (( count > 1 )); do
        "$tool" -w 10 -D "$CHAIN" 2
        count=$((count - 1))
    done
    "$tool" -w 10 -I "$CHAIN" 1 -i lo -j ACCEPT
    if [[ $tool == iptables ]]; then
        "$tool" -w 10 -I "$CHAIN" 2 -i "$LAN_IFACE" -s "$LAN_CIDR" -p tcp --dport 8883 -j ACCEPT
    fi
    if ! "$tool" -w 10 -C INPUT -p tcp -m multiport --dports 1883,8883 -j "$CHAIN" 2>/dev/null; then
        "$tool" -w 10 -I INPUT 1 -p tcp -m multiport --dports 1883,8883 -j "$CHAIN"
    fi
    "$tool" -w 10 -S "$CHAIN"
}

main() {
    local action=${1:-apply} tool
    [[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; return 1; }
    case "$action" in apply|remove|status) ;; *) echo 'Usage: apply-smarthome-firewall.sh [apply|remove|status]' >&2; return 2 ;; esac
    if [[ $action == apply ]]; then validate_lan; fi
    for tool in iptables ip6tables; do
        command -v "$tool" >/dev/null
        case "$action" in
            apply) apply_rules "$tool" ;;
            remove) remove_rules "$tool" ;;
            status)
                "$tool" -w 10 -S "$CHAIN"
                "$tool" -w 10 -C INPUT -p tcp -m multiport --dports 1883,8883 -j "$CHAIN"
                ;;
        esac
    done
    echo "MQTT firewall: $action (TLS: IPv4 LAN + loopback; plaintext: loopback only)."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
