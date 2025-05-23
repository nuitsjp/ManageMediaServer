#!/bin/bash

# メインセットアップスクリプト
# Usage: ./setup.sh [category] [--skip-input]
#   category: docker, immich, jellyfin, cloudflare, rclone, all
#   --skip-input: 対話モードをスキップ（事前設定ファイル使用）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 共通ライブラリを読み込み
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"

# メイン処理
main() {
    local category="${1:-all}"
    local skip_input="${2:-}"
    
    log_info "=== MediaServer Setup Script Started ==="
    log_info "Category: $category"
    
    # 事前チェック
    check_prerequisites
    
    # 設定の初期化
    if [[ "$skip_input" != "--skip-input" ]]; then
        initialize_config "$category"
    fi
    
    # カテゴリー別実行
    case "$category" in
        "docker")
            run_docker_setup
            ;;
        "immich")
            run_immich_setup
            ;;
        "jellyfin")
            run_jellyfin_setup
            ;;
        "cloudflare")
            run_cloudflare_setup
            ;;
        "rclone")
            run_rclone_setup
            ;;
        "all")
            run_full_setup
            ;;
        *)
            log_error "Unknown category: $category"
            show_usage
            exit 1
            ;;
    esac
    
    log_success "=== Setup completed successfully ==="
}

# 各セットアップ関数
run_docker_setup() {
    log_info "Starting Docker setup..."
    "$SCRIPT_DIR/install/install-docker.sh"
}

run_immich_setup() {
    log_info "Starting Immich setup..."
    "$SCRIPT_DIR/install/install-immich.sh"
}

run_jellyfin_setup() {
    log_info "Starting Jellyfin setup..."
    "$SCRIPT_DIR/install/install-jellyfin.sh"
}

run_cloudflare_setup() {
    log_info "Starting Cloudflare setup..."
    "$SCRIPT_DIR/install/install-cloudflared.sh"
}

run_rclone_setup() {
    log_info "Starting rclone setup..."
    "$SCRIPT_DIR/install/install-rclone.sh"
}

run_full_setup() {
    log_info "Starting full setup..."
    run_docker_setup
    run_immich_setup
    run_jellyfin_setup
    run_cloudflare_setup
    run_rclone_setup
}

# 前提条件チェック
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # OS確認
    if ! grep -q "Ubuntu" /etc/os-release; then
        log_warning "This script is designed for Ubuntu. Proceed with caution."
    fi
    
    # sudo権限確認
    if ! sudo -n true 2>/dev/null; then
        log_info "sudo access required. Please enter password if prompted."
    fi
    
    # 必要ディレクトリ作成
    ensure_directories
}

# 使用方法表示
show_usage() {
    cat << EOF
Usage: $0 [category] [--skip-input]

Categories:
  docker      - Install Docker and Docker Compose
  immich      - Setup Immich photo management
  jellyfin    - Setup Jellyfin media server
  cloudflare  - Setup Cloudflare Tunnel
  rclone      - Setup rclone for cloud storage
  all         - Run all setups (default)

Options:
  --skip-input - Skip interactive configuration (use existing config)

Examples:
  $0                    # Full interactive setup
  $0 docker             # Docker setup only
  $0 all --skip-input   # Full setup with existing config
EOF
}

# スクリプト実行
main "$@"
