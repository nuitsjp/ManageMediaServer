#!/bin/bash
# 共通ライブラリ（ログ、ユーティリティ）

# カラーコード定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# ログ機能
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

log_debug() {
    if [ "${DEBUG:-0}" = "1" ]; then
        echo -e "${GRAY}[DEBUG]${NC} $1"
    fi
}

# ユーティリティ関数
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

wait_for_service() {
    local service_name=$1
    local timeout=${2:-30}
    local count=0
    
    log_info "${service_name}の起動を待機中..."
    
    while [ $count -lt $timeout ]; do
        if systemctl is-active --quiet "$service_name"; then
            log_success "${service_name}が起動しました"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    log_error "${service_name}の起動がタイムアウトしました"
}

ensure_dir_exists() {
    local dir=$1
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log_debug "ディレクトリを作成しました: $dir"
    fi
}

confirm_action() {
    local message=$1
    echo -n "$message (y/N): "
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# WSL環境判定
is_wsl() {
    grep -qE "(Microsoft|WSL)" /proc/version 2>/dev/null
}

# 権限チェック
check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "このスクリプトはroot権限で実行してください"
    fi
}

check_user() {
    if [ "$(id -u)" = "0" ]; then
        log_error "このスクリプトは一般ユーザーで実行してください"
    fi
}
