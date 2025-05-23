#!/bin/bash

# 共通ライブラリ - ログ、ユーティリティ関数

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ログレベル
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# ログ関数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_debug() {
    if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
        echo -e "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*"
    fi
}

# エラーハンドリング
handle_error() {
    local exit_code=$?
    local line_number=$1
    log_error "Script failed at line $line_number with exit code $exit_code"
    exit $exit_code
}

# エラートラップ設定
trap 'handle_error $LINENO' ERR

# ユーティリティ関数
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_service_running() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

wait_for_service() {
    local service_name="$1"
    local max_wait="${2:-30}"
    local count=0
    
    log_info "Waiting for $service_name to start..."
    while ! is_service_running "$service_name" && [ $count -lt $max_wait ]; do
        sleep 1
        ((count++))
    done
    
    if [ $count -ge $max_wait ]; then
        log_error "Service $service_name failed to start within ${max_wait}s"
        return 1
    fi
    
    log_success "Service $service_name is running"
}

# ディレクトリ作成
ensure_directories() {
    local dirs=(
        "/mnt/mediaserver"
        "/mnt/mediaserver/photos"
        "/mnt/mediaserver/videos"
        "/mnt/mediaserver/music"
        "/mnt/mediaserver/backups"
        "/mnt/mediaserver/config"
        "/mnt/mediaserver/config/immich"
        "/mnt/mediaserver/config/jellyfin"
        "/mnt/mediaserver/config/rclone"
        "$PROJECT_ROOT/logs"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_info "Creating directory: $dir"
            sudo mkdir -p "$dir"
            sudo chown "$USER:$USER" "$dir" 2>/dev/null || true
        fi
    done
}

# 確認プロンプト
confirm() {
    local message="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        prompt="$message [Y/n]: "
    else
        prompt="$message [y/N]: "
    fi
    
    read -p "$prompt" -r reply
    
    case "$reply" in
        [Yy]* ) return 0 ;;
        [Nn]* ) return 1 ;;
        "" ) [[ "$default" == "y" ]] && return 0 || return 1 ;;
        * ) log_warning "Please answer yes or no."; confirm "$message" "$default" ;;
    esac
}

# バックアップ作成
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Backing up $file to $backup"
        cp "$file" "$backup"
    fi
}
