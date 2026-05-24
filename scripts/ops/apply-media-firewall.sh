#!/usr/bin/env bash

set -euo pipefail

ACTION="${1:-apply}"
CHAIN="${DOCKER_USER_CHAIN:-DOCKER-USER}"
TAILSCALE_IFACE="${TAILSCALE_IFACE:-tailscale0}"
MEDIA_FIREWALL_PORTS="${MEDIA_FIREWALL_PORTS:-2283 8096}"

usage() {
    cat <<'USAGE'
Usage: apply-media-firewall.sh [apply|remove|status]

Environment:
  LAN_CIDR              Required for apply/remove. Home LAN CIDR, e.g. 192.168.1.0/24.
  TAILSCALE_IFACE       Tailscale interface name. Default: tailscale0.
  MEDIA_FIREWALL_PORTS  Space-separated TCP ports. Default: "2283 8096".
USAGE
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: root 権限で実行してください" >&2
        exit 1
    fi
}

require_lan_cidr() {
    if [[ -z "${LAN_CIDR:-}" ]]; then
        echo "ERROR: LAN_CIDR が未設定です" >&2
        exit 1
    fi
}

ensure_chain() {
    if ! iptables -S "${CHAIN}" >/dev/null 2>&1; then
        echo "ERROR: ${CHAIN} chain が見つかりません。Docker 起動後に実行してください" >&2
        exit 1
    fi
}

rule_args() {
    local port="$1"
    printf '%s\n' \
        -p tcp \
        -m conntrack \
        --ctorigdstport "${port}" \
        ! -s "${LAN_CIDR}" \
        ! -i "${TAILSCALE_IFACE}" \
        -j DROP
}

apply_rule() {
    local port="$1"
    mapfile -t args < <(rule_args "${port}")

    if iptables -C "${CHAIN}" "${args[@]}" 2>/dev/null; then
        echo "OK: ${CHAIN} rule already exists for tcp/${port}"
        return
    fi

    iptables -I "${CHAIN}" 1 "${args[@]}"
    echo "ADD: ${CHAIN} drops non-LAN/non-Tailscale traffic for tcp/${port}"
}

remove_rule() {
    local port="$1"
    mapfile -t args < <(rule_args "${port}")

    while iptables -C "${CHAIN}" "${args[@]}" 2>/dev/null; do
        iptables -D "${CHAIN}" "${args[@]}"
        echo "DEL: ${CHAIN} rule for tcp/${port}"
    done
}

show_status() {
    iptables -S "${CHAIN}"
}

case "${ACTION}" in
    apply)
        require_root
        require_lan_cidr
        ensure_chain
        for port in ${MEDIA_FIREWALL_PORTS}; do
            apply_rule "${port}"
        done
        show_status
        ;;
    remove)
        require_root
        require_lan_cidr
        ensure_chain
        for port in ${MEDIA_FIREWALL_PORTS}; do
            remove_rule "${port}"
        done
        show_status
        ;;
    status)
        require_root
        show_status
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
