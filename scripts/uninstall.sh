#!/bin/bash
#
# メディアサーバーのアンインストールスクリプト
# Usage: ./uninstall.sh [category] [--force]
#   category: docker, immich, jellyfin, cloudflare, rclone, all
#   --force: 確認プロンプトをスキップ（自動アンインストール）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 共通ライブラリを読み込み
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"

# メイン処理
main() {
    local category="${1:-all}"
    local force_option="${2:-}"
    
    log_info "=== メディアサーバーアンインストールスクリプト開始 ==="
    log_info "カテゴリー: $category"
    
    # 強制モードチェック
    local force=false
    if [[ "$force_option" == "--force" ]]; then
        force=true
        log_warning "強制モードが有効です。確認プロンプトなしで処理を実行します。"
    fi
    
    # 設定の読み込み
    load_config
    
    # カテゴリー別実行（依存関係逆順）
    case "$category" in
        "rclone")
            run_rclone_uninstall "$force"
            ;;
        "cloudflare")
            run_cloudflare_uninstall "$force"
            ;;
        "jellyfin")
            run_jellyfin_uninstall "$force"
            ;;
        "immich")
            run_immich_uninstall "$force"
            ;;
        "docker")
            run_docker_uninstall "$force"
            ;;
        "all")
            run_full_uninstall "$force"
            ;;
        *)
            log_error "不明なカテゴリー: $category"
            show_usage
            exit 1
            ;;
    esac
    
    log_success "=== アンインストールが正常に完了しました ==="
}

# 各アンインストール関数
run_rclone_uninstall() {
    local force=$1
    
    log_info "rcloneアンインストールを開始します..."
    
    if [[ -f "$SCRIPT_DIR/uninstall/uninstall-rclone.sh" ]]; then
        "$SCRIPT_DIR/uninstall/uninstall-rclone.sh" $([[ "$force" == "true" ]] && echo "--force")
    else
        log_warning "rcloneアンインストールスクリプトが見つかりません"
    fi
}

run_cloudflare_uninstall() {
    local force=$1
    
    log_info "Cloudflare Tunnelアンインストールを開始します..."
    
    if [[ -f "$SCRIPT_DIR/uninstall/uninstall-cloudflared.sh" ]]; then
        "$SCRIPT_DIR/uninstall/uninstall-cloudflared.sh" $([[ "$force" == "true" ]] && echo "--force")
    else
        log_warning "Cloudflare Tunnelアンインストールスクリプトが見つかりません"
    fi
}

run_jellyfin_uninstall() {
    local force=$1
    
    log_info "Jellyfinアンインストールを開始します..."
    
    if [[ -f "$SCRIPT_DIR/uninstall/uninstall-jellyfin.sh" ]]; then
        "$SCRIPT_DIR/uninstall/uninstall-jellyfin.sh" $([[ "$force" == "true" ]] && echo "--force")
    else
        log_warning "Jellyfinアンインストールスクリプトが見つかりません"
    fi
}

run_immich_uninstall() {
    local force=$1
    
    log_info "Immichアンインストールを開始します..."
    
    if [[ -f "$SCRIPT_DIR/uninstall/uninstall-immich.sh" ]]; then
        "$SCRIPT_DIR/uninstall/uninstall-immich.sh" $([[ "$force" == "true" ]] && echo "--force")
    else
        log_warning "Immichアンインストールスクリプトが見つかりません"
    fi
}

run_docker_uninstall() {
    local force=$1
    
    log_info "Dockerアンインストールを開始します..."
    
    # Docker設定は管理者権限が必要
    if [ "$(id -u)" -ne 0 ]; then
        log_warning "Docker設定には管理者権限が必要です。sudoで実行します..."
        if [[ "$force" == "true" ]]; then
            sudo "$SCRIPT_DIR/uninstall/uninstall-docker.sh" --force
        else
            sudo "$SCRIPT_DIR/uninstall/uninstall-docker.sh"
        fi
    else
        if [[ "$force" == "true" ]]; then
            "$SCRIPT_DIR/uninstall/uninstall-docker.sh" --force
        else
            "$SCRIPT_DIR/uninstall/uninstall-docker.sh"
        fi
    fi
}

run_full_uninstall() {
    local force=$1
    
    if [[ "$force" != "true" ]]; then
        log_warning "全てのサービスとデータを削除しようとしています。"
        if ! confirm "本当に続行しますか？" "n"; then
            log_info "アンインストールを中止しました。"
            exit 0
        fi
    fi
    
    log_info "完全アンインストールを開始します（依存関係の逆順）..."
    
    # 依存関係を考慮した逆順でアンインストール
    run_rclone_uninstall "$force"
    run_cloudflare_uninstall "$force"
    run_jellyfin_uninstall "$force"
    run_immich_uninstall "$force"
    run_docker_uninstall "$force"
}

# 使用方法表示
show_usage() {
    cat << EOF
使用方法: $0 [カテゴリー] [--force]

カテゴリー:
  docker      - DockerとDocker Composeをアンインストール
  immich      - Immich写真管理システムをアンインストール
  jellyfin    - Jellyfinメディアサーバーをアンインストール
  cloudflare  - Cloudflare Tunnelをアンインストール
  rclone      - rcloneをアンインストール
  all         - すべてのサービスをアンインストール（依存関係の逆順、デフォルト）

オプション:
  --force     - 確認プロンプトをスキップして強制的にアンインストール

例:
  $0                # 対話式で完全アンインストール
  $0 docker         # Dockerのみアンインストール
  $0 all --force    # 確認なしで完全アンインストール
EOF
}

# スクリプト実行
main "$@"
