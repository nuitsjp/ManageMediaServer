#!/bin/bash
# 統合サービス管理スクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }

# 使用方法表示
show_usage() {
    cat << USAGE
使用方法: $0 [コマンド] [オプション]

統合サービス管理を行います。

コマンド:
    start            すべてのサービスを起動
    stop             すべてのサービスを停止
    restart          すべてのサービスを再起動
    status           サービス状態確認
    health           ヘルスチェック実行
    update           システム更新実行

オプション:
    --detailed       詳細情報表示
    --dry-run        実行予定のみ表示
    --help           このヘルプを表示

例:
    ./manage-services.sh start                # 全サービス起動
    ./manage-services.sh status --detailed    # 詳細状態確認
    ./manage-services.sh health               # ヘルスチェック

USAGE
}

# サービス起動
start_services() {
    echo "[INFO] === サービス起動 ==="
    "$SCRIPT_DIR/ops/start-services.sh"
    echo "[SUCCESS] サービス起動完了"
}

# サービス停止
stop_services() {
    echo "[INFO] === サービス停止 ==="
    "$SCRIPT_DIR/ops/stop-services.sh"
    echo "[SUCCESS] サービス停止完了"
}

# サービス状態確認
check_status() {
    echo "[INFO] === サービス状態確認 ==="
    
    # URL応答確認
    echo "[INFO] サービス応答確認:"
    if curl -s http://localhost:2283/api/server-info >/dev/null 2>&1; then
        echo "[OK] Immich API: 応答正常"
    else
        echo "[WARNING] Immich API: 応答なし"
    fi
    
    if curl -s http://localhost:8096/health >/dev/null 2>&1; then
        echo "[OK] Jellyfin: 応答正常"
    else
        echo "[WARNING] Jellyfin: 応答なし"
    fi
    
    if [[ "${DETAILED:-false}" == "true" ]]; then
        echo "[INFO] 詳細ヘルスチェック実行中..."
        "$SCRIPT_DIR/../monitoring/health-check.sh" --detailed
    fi
}

# メイン処理
main() {
    local command=""
    
    # オプション解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            start|stop|restart|status|health|update)
                command="$1"
                shift
                ;;
            --detailed)
                DETAILED=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                echo "[ERROR] 不明なオプション: $1" >&2
                exit 1
                ;;
        esac
    done
    
    # コマンド実行
    case "${command:-}" in
        start)
            start_services
            ;;
        stop)
            stop_services
            ;;
        restart)
            stop_services
            sleep 3
            start_services
            ;;
        status)
            check_status
            ;;
        health)
            "$SCRIPT_DIR/../monitoring/health-check.sh" ${DETAILED:+--detailed}
            ;;
        update)
            "$SCRIPT_DIR/../maintenance/update-system.sh" ${DRY_RUN:+--dry-run}
            ;;
        "")
            echo "[ERROR] コマンドが指定されていません" >&2
            show_usage
            exit 1
            ;;
        *)
            echo "[ERROR] 不明なコマンド: $command" >&2
            show_usage
            exit 1
            ;;
    esac
}

# スクリプト実行
main "$@"
