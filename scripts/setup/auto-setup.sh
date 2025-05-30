#!/bin/bash
# --- root権限チェック・昇格 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "[INFO] Root権限が必要です。sudoで再実行します..."
    exec sudo bash "$0" "$@"
fi
# --------------------------------

# セキュリティ警告: 家庭内クローズドネットワーク前提の設定
# 本スクリプトはシステム構成（system-architecture.md）に基づき、
# 家庭内の信頼できるネットワーク環境での使用を前提としています。

# 統合セットアップスクリプト（環境自動判定）
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/system.sh" || log_error "system.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/docker.sh" || log_error "docker.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/immich.sh" || log_error "immich.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/jellyfin.sh" || log_error "jellyfin.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/rclone.sh" || log_error "rclone.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/services.sh" || log_error "services.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/ui.sh" || log_error "ui.sh の読み込みに失敗"

# 環境変数読み込み
load_environment

# メイン処理
main() {
    local dry_run=false
    local force=false
    local test_security=false
    local test_mode=false
    local security_only=false
    
    # 引数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --debug)
                export DEBUG=1
                log_debug "デバッグモードが有効になりました"
                ;;
            --force)
                force=true
                export FORCE=true
                ;;
            --test-mode)
                test_mode=true
                log_info "テストモードが有効になりました"
                ;;
            --security-only)
                security_only=true
                log_info "セキュリティ設定のみ実行します"
                ;;
            --test-security)
                test_security=true
                log_info "セキュリティ設定テストモードが有効になりました"
                ;;
            --dry-run)
                dry_run=true
                log_info "ドライランモードが有効になりました"
                ;;
            *)
                log_error "不明なオプション: $1"
                echo "ヘルプ: $0 --help"
                exit 1
                ;;
        esac
        shift
    done
    
    log_info "=== 家庭用メディアサーバー自動セットアップ開始 ==="
    
    # 環境判定
    local env_type=$(detect_environment)
    
    # テストモード + セキュリティのみの処理
    if [ "$test_mode" = "true" ] && [ "$security_only" = "true" ]; then
        log_info "テストモードでセキュリティ設定のみを実行します"
        "$SCRIPT_DIR/setup-prod.sh" --test-mode --security-only
        exit $?
    fi
    
    # セキュリティのみの処理
    if [ "$security_only" = "true" ]; then
        log_info "セキュリティ設定のみを実行します"
        "$SCRIPT_DIR/setup-prod.sh" --security-only
        exit $?
    fi
    
    # セキュリティテストモード時の特別処理
    if [ "$test_security" = "true" ]; then
        if [ "$env_type" = "dev" ]; then
            log_warning "WSL環境でセキュリティ設定をテスト実行します"
            log_info "セキュリティ設定のみを実行します"
            # WSL環境でもテストモードで実行
            "$SCRIPT_DIR/setup-prod.sh" --test-mode --security-only
            exit $?
        elif [ "$env_type" = "prod" ]; then
            log_info "本番環境でセキュリティ設定をテスト実行します"
            "$SCRIPT_DIR/setup-prod.sh" --test-mode --security-only
            exit $?
        else
            log_error "サポートされていない環境です: $env_type"
            exit 1
        fi
    fi

    # 環境情報表示
    show_environment_info "$env_type"
    
    # 環境チェック
    check_environment "$env_type"

    if [ "$dry_run" = "true" ]; then
        log_info "=== ドライラン: 以下の処理が実行されます ==="
        echo "1. 事前チェック"
        echo "2. ディレクトリ準備"
        echo "3. 設定ファイル展開"
        echo "4. システムパッケージインストール"
        echo "5. Dockerインストール"
        echo "5a. Docker Compose プラグインインストール"
        echo "5b. mediaserverユーザー作成・権限設定"
        echo "6. アプリケーションセットアップ"
        echo "7. rcloneセットアップ"
        echo "8. systemdサービス設定"
        echo "9. セキュリティ設定（本番環境のみ）"
        echo "   - 環境: $env_type"
        if [ "$env_type" = "prod" ]; then
            echo "   - ファイアウォール設定（ローカルネットワーク制限）"
            echo "   - fail2ban設定（家庭内IP除外）"
            echo "   - SSH強化（家庭内利便性考慮）"
            echo "   - 自動セキュリティ更新"
        else
            echo "   - 開発環境設定を適用"
        fi
        log_info "実際の実行を行う場合は --dry-run オプションを外してください"
        exit 0
    fi
    
    # 実行確認
    if [ "$force" != "true" ]; then
        log_warning "上記の設定でセットアップを実行します"
        if ! confirm_action "続行しますか？"; then
            log_info "セットアップをキャンセルしました"
            exit 0
        fi
    fi
    
    # セットアップ実行
    log_info "=== セットアップ処理開始 ==="
    
    # 1. 事前チェック
    pre_check "$env_type"

    # 2. ディレクトリ準備
    prepare_directories

    # 3. 設定ファイル展開
    deploy_config_files

    # 4. システムパッケージインストール
    install_system_packages

    # 5. Dockerインストール
    install_docker
    
    # 5a. Docker Compose プラグインインストール
    install_docker_compose_plugin
    
    # 5b. mediaserverユーザー作成・権限設定（Dockerインストール後）
    setup_mediaserver_user

    # 6. アプリケーションセットアップ
    setup_immich
    setup_jellyfin

    # 7. rclone セットアップ
    setup_rclone

    # 8. systemdサービス設定
    setup_systemd_services

    # 9. セキュリティ設定（本番環境のみ）
    if [ "$env_type" = "prod" ]; then
        log_info "=== 本番環境セキュリティ設定 ==="
        
        # setup-prod.sh の該当関数を呼び出し
        "$SCRIPT_DIR/setup-prod.sh" --security-only || {
            log_warning "セキュリティ設定で一部エラーが発生しましたが、継続します"
        }
    fi

    log_success "=== 自動セットアップ完了 ==="
    
    # 完了メッセージ・次のステップ案内
    show_completion_message "$env_type"
}

# スクリプト実行
main "$@"
