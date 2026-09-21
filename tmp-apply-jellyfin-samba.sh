#!/usr/bin/env bash

set -euo pipefail

SHARE_USER="${SAMBA_USER:-mediaserver}"
SHARE_GROUP="${SAMBA_GROUP:-mediaserver}"
SMB_CONF="/etc/samba/smb.conf"
BACKUP_DIR="/etc/samba/backups"
TAILSCALE_IFACE="${TAILSCALE_IFACE:-tailscale0}"

MARKER_BEGIN="# BEGIN ManageMediaServer Jellyfin Samba shares"
MARKER_END="# END ManageMediaServer Jellyfin Samba shares"

SHARE_DIRS=(
    "/mnt/data/jellyfin/music-videos"
    "/mnt/data/jellyfin/movies"
    "/mnt/data/jellyfin/tv"
)

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: root 権限で実行してください。例: sudo $0" >&2
        exit 1
    fi
}

ensure_package() {
    if command -v smbd >/dev/null 2>&1; then
        echo "OK: samba is already installed"
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "ERROR: samba が未導入ですが apt-get が見つかりません" >&2
        exit 1
    fi

    echo "INSTALL: samba"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y samba
}

require_commands() {
    local missing=0
    for command_name in getent install mktemp sed cp testparm systemctl smbpasswd pdbedit; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            echo "ERROR: required command not found: ${command_name}" >&2
            missing=1
        fi
    done

    if [[ "${missing}" -ne 0 ]]; then
        exit 1
    fi
}

ensure_user_and_group() {
    if ! getent passwd "${SHARE_USER}" >/dev/null; then
        echo "ERROR: user not found: ${SHARE_USER}" >&2
        exit 1
    fi

    if ! getent group "${SHARE_GROUP}" >/dev/null; then
        echo "ERROR: group not found: ${SHARE_GROUP}" >&2
        exit 1
    fi

    echo "OK: samba write user is ${SHARE_USER}:${SHARE_GROUP}"
}

ensure_directories() {
    for share_dir in "${SHARE_DIRS[@]}"; do
        install -d -o "${SHARE_USER}" -g "${SHARE_GROUP}" -m 2775 "${share_dir}"
        chmod 2775 "${share_dir}"
        chown "${SHARE_USER}:${SHARE_GROUP}" "${share_dir}"
        echo "OK: ${share_dir}"
    done
}

backup_smb_conf() {
    if [[ ! -f "${SMB_CONF}" ]]; then
        echo "ERROR: ${SMB_CONF} が見つかりません" >&2
        exit 1
    fi

    install -d -m 0755 "${BACKUP_DIR}"
    local backup_path="${BACKUP_DIR}/smb.conf.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "${SMB_CONF}" "${backup_path}"
    echo "BACKUP: ${backup_path}"
}

write_smb_conf() {
    local tmp_file
    tmp_file="$(mktemp)"
    trap 'rm -f "${tmp_file}"' EXIT

    sed "\|^${MARKER_BEGIN}$|,\|^${MARKER_END}$|d" "${SMB_CONF}" > "${tmp_file}"

    cat >> "${tmp_file}" <<EOF

${MARKER_BEGIN}
[jellyfin-music-videos]
    path = /mnt/data/jellyfin/music-videos
    browseable = yes
    read only = no
    guest ok = no
    valid users = ${SHARE_USER}
    force user = ${SHARE_USER}
    force group = ${SHARE_GROUP}
    create mask = 0664
    directory mask = 0775
    hosts allow = 127. 10. 192.168. 172.16.0.0/12 100.64.0.0/10
    hosts deny = ALL

[jellyfin-movies]
    path = /mnt/data/jellyfin/movies
    browseable = yes
    read only = no
    guest ok = no
    valid users = ${SHARE_USER}
    force user = ${SHARE_USER}
    force group = ${SHARE_GROUP}
    create mask = 0664
    directory mask = 0775
    hosts allow = 127. 10. 192.168. 172.16.0.0/12 100.64.0.0/10
    hosts deny = ALL

[jellyfin-tv]
    path = /mnt/data/jellyfin/tv
    browseable = yes
    read only = no
    guest ok = no
    valid users = ${SHARE_USER}
    force user = ${SHARE_USER}
    force group = ${SHARE_GROUP}
    create mask = 0664
    directory mask = 0775
    hosts allow = 127. 10. 192.168. 172.16.0.0/12 100.64.0.0/10
    hosts deny = ALL
${MARKER_END}
EOF

    install -m 0644 "${tmp_file}" "${SMB_CONF}"
    echo "UPDATE: ${SMB_CONF}"
}

ensure_samba_user() {
    if pdbedit -L | cut -d: -f1 | grep -Fxq "${SHARE_USER}"; then
        echo "OK: samba user already exists: ${SHARE_USER}"
    else
        echo "INPUT: Windows から Samba 共有へ接続するための ${SHARE_USER} 用 Samba パスワードを入力してください"
        smbpasswd -a "${SHARE_USER}"
    fi

    smbpasswd -e "${SHARE_USER}"
}

validate_and_restart() {
    testparm -s "${SMB_CONF}" >/dev/null
    echo "OK: testparm validation passed"

    systemctl enable --now smbd
    systemctl restart smbd

    if systemctl list-unit-files nmbd.service >/dev/null 2>&1; then
        systemctl enable --now nmbd
        systemctl restart nmbd
    fi
}

show_result() {
    echo
    echo "RESULT: Samba shares"
    testparm -s "${SMB_CONF}" 2>/dev/null | sed -n '/^\[jellyfin-music-videos\]/,/^$/p;/^\[jellyfin-movies\]/,/^$/p;/^\[jellyfin-tv\]/,/^$/p'

    echo
    echo "RESULT: smbd status"
    systemctl --no-pager --full status smbd || true

    echo
    echo "RESULT: share directories"
    find /mnt/data/jellyfin -maxdepth 1 -type d -printf '%M %u:%g %p\n' | sort

    echo
    if command -v ufw >/dev/null 2>&1; then
        echo "INFO: ufw status"
        ufw status || true
    fi

    echo
    echo "NEXT: Windows から \\\\home-ubuntu\\jellyfin-music-videos へ接続し、ユーザー ${SHARE_USER} と設定した Samba パスワードでログインしてください。"
    echo "NEXT: 名前解決できない場合は \\\\<LAN IP>\\jellyfin-music-videos または \\\\<Tailscale IP>\\jellyfin-music-videos を使ってください。"
}

main() {
    require_root
    ensure_package
    require_commands
    ensure_user_and_group
    ensure_directories
    backup_smb_conf
    write_smb_conf
    ensure_samba_user
    validate_and_restart
    show_result
}

main "$@"
