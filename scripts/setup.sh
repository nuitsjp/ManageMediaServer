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
    
    log_info "=== メディアサーバーセットアップスクリプト開始 ==="
    log_info "カテゴリー: $category"
    
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
            log_error "不明なカテゴリー: $category"
            show_usage
            exit 1
            ;;
    esac
    
    log_success "=== セットアップが正常に完了しました ==="
}

# 各セットアップ関数
run_docker_setup() {
    log_info "Starting Docker setup..."
    
    # Docker設定は管理者権限が必要
    if [ "$(id -u)" -ne 0 ]; then
        log_warning "Docker設定には管理者権限が必要です。sudoで実行します..."
        sudo "$SCRIPT_DIR/install/install-docker.sh"
    else
        "$SCRIPT_DIR/install/install-docker.sh"
    fi
}

run_immich_setup() {
    log_info "Immichセットアップを開始します..."
    "$SCRIPT_DIR/install/install-immich.sh"
}

run_jellyfin_setup() {
    log_info "Jellyfinセットアップを開始します..."
    "$SCRIPT_DIR/install/install-jellyfin.sh"
}

run_cloudflare_setup() {
    log_info "Cloudflareセットアップを開始します..."
    "$SCRIPT_DIR/install/install-cloudflared.sh"
}

run_rclone_setup() {
    log_info "rcloneセットアップを開始します..."
    "$SCRIPT_DIR/install/install-rclone.sh"
}

run_full_setup() {
    log_info "完全セットアップを開始します..."
    run_docker_setup
    run_immich_setup
    run_jellyfin_setup
    run_cloudflare_setup
    run_rclone_setup
}

# 前提条件チェック
check_prerequisites() {
    log_info "前提条件チェックを行っています..."
    
    # OS確認
    if ! grep -q "Ubuntu" /etc/os-release; then
        log_warning "このスクリプトはUbuntu用に設計されています。他のOS環境では注意して実行してください。"
    fi
    
    # Ubuntu バージョン確認
    if grep -q "VERSION_ID=\"24.04\"" /etc/os-release; then
        log_success "Ubuntu 24.04 LTSが検出されました。"
    else
        log_warning "Ubuntu 24.04 LTS以外の環境が検出されました。互換性の問題が発生する可能性があります。"
    fi
    
    # sudo権限確認
    if ! sudo -n true 2>/dev/null; then
        log_warning "この処理には管理者権限(sudo)が必要です。"
        log_info "Docker、Immich、Jellyfinなどのインストールにはsudoパスワードの入力を求められます。"
        sudo -v || {
            log_error "sudo権限が取得できませんでした。スクリプトを終了します。"
            exit 1
        }
    fi
    
    # 必要ディレクトリ作成
    ensure_directories
}

# 使用方法表示
show_usage() {
    cat << EOF
使用方法: $0 [カテゴリー] [--skip-input]

カテゴリー:
  docker      - DockerとDocker Composeをインストール
  immich      - Immich写真管理システムをセットアップ
  jellyfin    - Jellyfinメディアサーバーをセットアップ
  cloudflare  - Cloudflare Tunnelをセットアップ
  rclone      - クラウドストレージ連携用rcloneをセットアップ
  all         - すべてのセットアップを実行（デフォルト）

オプション:
  --skip-input - 対話式設定をスキップ（既存の設定を使用）

例:
  $0                    # 完全な対話式セットアップ
  $0 docker             # Dockerのみセットアップ
  $0 all --skip-input   # 既存設定での完全セットアップ
EOF
}

# スクリプト実行
main "$@"
