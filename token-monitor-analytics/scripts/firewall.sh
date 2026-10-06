#!/usr/bin/env bash
set -euo pipefail
source /etc/token-monitor-analytics/network.env
# Keep Analytics TCP packets small without lowering the Tailscale MTU below
# IPv6's minimum. Both SYN directions must advertise the smaller MSS.
mss_rule() {
  local action=$1 chain=$2
  shift 2
  iptables -w -t mangle "$action" "$chain" -p tcp "$@" \
    --tcp-flags SYN,RST SYN -m comment --comment tma-mss \
    -j TCPMSS --set-mss 1100
}
mss_apply() {
  mss_rule -C INPUT -i tailscale0 -d "$TAILSCALE_IP" --dport 3000 2>/dev/null || \
    mss_rule -A INPUT -i tailscale0 -d "$TAILSCALE_IP" --dport 3000
  mss_rule -C OUTPUT -o tailscale0 -s "$TAILSCALE_IP" --sport 3000 2>/dev/null || \
    mss_rule -A OUTPUT -o tailscale0 -s "$TAILSCALE_IP" --sport 3000
}
mss_remove() {
  while mss_rule -C INPUT -i tailscale0 -d "$TAILSCALE_IP" --dport 3000 2>/dev/null; do
    mss_rule -D INPUT -i tailscale0 -d "$TAILSCALE_IP" --dport 3000
  done
  while mss_rule -C OUTPUT -o tailscale0 -s "$TAILSCALE_IP" --sport 3000 2>/dev/null; do
    mss_rule -D OUTPUT -o tailscale0 -s "$TAILSCALE_IP" --sport 3000
  done
}
case "${1:-apply}" in
  apply)
    mss_apply
    iptables -N TMA-HTTP 2>/dev/null || iptables -S TMA-HTTP >/dev/null
    iptables -F TMA-HTTP
    iptables -A TMA-HTTP -i lo -j ACCEPT
    iptables -A TMA-HTTP -s "$LAN_CIDR" -d "$LAN_IP" -j ACCEPT
    iptables -A TMA-HTTP -i tailscale0 -d "$TAILSCALE_IP" -j ACCEPT
    iptables -A TMA-HTTP -j DROP
    iptables -C INPUT -p tcp --dport 3000 -j TMA-HTTP 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 3000 -j TMA-HTTP
    ;;
  remove)
    mss_remove
    while iptables -C INPUT -p tcp --dport 3000 -j TMA-HTTP 2>/dev/null; do
      iptables -D INPUT -p tcp --dport 3000 -j TMA-HTTP
    done
    iptables -F TMA-HTTP
    iptables -X TMA-HTTP
    ;;
  *) exit 2 ;;
esac
