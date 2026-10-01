#!/usr/bin/env bash
set -euo pipefail
source /etc/token-monitor-analytics/network.env
case "${1:-apply}" in
  apply)
    iptables -N TMA-HTTP 2>/dev/null || iptables -S TMA-HTTP >/dev/null
    iptables -F TMA-HTTP
    iptables -A TMA-HTTP -i lo -j ACCEPT
    iptables -A TMA-HTTP -s "$LAN_CIDR" -d "$LAN_IP" -j ACCEPT
    iptables -A TMA-HTTP -i tailscale0 -d "$TAILSCALE_IP" -j ACCEPT
    iptables -A TMA-HTTP -j DROP
    iptables -C INPUT -p tcp --dport 3000 -j TMA-HTTP 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 3000 -j TMA-HTTP
    ;;
  remove)
    while iptables -C INPUT -p tcp --dport 3000 -j TMA-HTTP 2>/dev/null; do
      iptables -D INPUT -p tcp --dport 3000 -j TMA-HTTP
    done
    iptables -F TMA-HTTP
    iptables -X TMA-HTTP
    ;;
  *) exit 2 ;;
esac
