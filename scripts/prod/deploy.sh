#!/bin/bash
# 本番デプロイスクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/env-loader.sh" || log_error "env-loader.sh の読み込みに失敗"

# 環境変数読み込み
load_environment

# 使用方法表示
show_usage() {
    cat << EOF
使用方法: $0 [オプション]

本番環境への安全なデプロイを実行します。

オプション:
    --backup         デプロイ前にバックアップを作成
    --rollback       前回のバックアップから復元
    --verify         デプロイ後の動作確認のみ実行
    --dry-run        実際のデプロイは行わず、実行予定の処理のみ表示
    --force          確認をスキップ
    --help           このヘルプを表示

例:
    ./deploy.sh --backup           # バックアップ付きデプロイ
    ./deploy.sh --rollback         # ロールバック
    ./deploy.sh --verify           # 動作確認のみ
    ./deploy.sh --dry-run          # ドライラン

EOF
}

# デプロイ前チェック
pre_deploy_check() {
    log_info "=== デプロイ前チェック ==="
    
    # 本番環境確認
    if is_wsl; then
        log_error "本番環境（Ubuntu Server）でのみ実行可能です"
    fi
    
    # systemdサービス状態確認
    local services=("docker" "immich" "jellyfin")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "サービス状態: $service (動作中)"
        else
            log_warning "サービス状態: $service (停止中)"
        fi
    done
    
    # ディスク容量確認
    local data_usage=$(df "$DATA_ROOT" | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$data_usage" -gt 85 ]; then
        log_warning "データ領域の使用率が高いです: ${data_usage}%"
    fi
    
    local backup_usage=$(df "$BACKUP_ROOT" | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$backup_usage" -gt 90 ]; then
        log_error "バックアップ領域の容量が不足しています: ${backup_usage}%"
    fi
    
    log_success "デプロイ前チェック完了"
}

# バックアップ作成
create_backup() {
    log_info "=== デプロイ前バックアップ作成 ==="
    
    local backup_date=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="$BACKUP_ROOT/deploy_backup_$backup_date"
    
    # バックアップディレクトリ作成
    ensure_dir_exists "$backup_dir"
    
    # 設定ファイルバックアップ
    log_info "設定ファイルをバックアップ中..."
    cp -r "$PROJECT_ROOT/docker" "$backup_dir/"
    cp -r "$PROJECT_ROOT/config" "$backup_dir/"
    
    # データベースバックアップ（Immich）
    if docker ps --format '{{.Names}}' | grep -q immich_postgres; then
        log_info "Immichデータベースをバックアップ中..."
        docker exec immich_postgres pg_dump -U postgres immich > "$backup_dir/immich_db_backup.sql"
    fi
    
    # メタデータバックアップ
    echo "backup_date=$backup_date" > "$backup_dir/backup_info.txt"
    echo "project_root=$PROJECT_ROOT" >> "$backup_dir/backup_info.txt"
    echo "git_commit=$(git rev-parse HEAD 2>/dev/null || echo 'unknown')" >> "$backup_dir/backup_info.txt"
    
    log_success "バックアップ作成完了: $backup_dir"
    echo "$backup_dir" > "$BACKUP_ROOT/.last_backup_path"
}

# ロールバック実行
perform_rollback() {
    log_info "=== ロールバック実行 ==="
    
    if [ ! -f "$BACKUP_ROOT/.last_backup_path" ]; then
        log_error "ロールバック用のバックアップが見つかりません"
    fi
    
    local backup_dir=$(cat "$BACKUP_ROOT/.last_backup_path")
    if [ ! -d "$backup_dir" ]; then
        log_error "バックアップディレクトリが存在しません: $backup_dir"
    fi
    
    log_warning "以下のバックアップからロールバックします:"
    cat "$backup_dir/backup_info.txt"
    
    if ! confirm_action "ロールバックを実行しますか？"; then
        log_info "ロールバックをキャンセルしました"
        exit 0
    fi
    
    # サービス停止
    log_info "サービスを停止中..."
    systemctl stop immich jellyfin 2>/dev/null || true
    
    # 設定復元
    log_info "設定ファイルを復元中..."
    cp -r "$backup_dir/docker" "$PROJECT_ROOT/"
    cp -r "$backup_dir/config" "$PROJECT_ROOT/"
    
    # データベース復元（必要に応じて）
    if [ -f "$backup_dir/immich_db_backup.sql" ]; then
        log_info "データベースの復元が必要な場合は、手動で実行してください:"
        log_info "cat $backup_dir/immich_db_backup.sql | docker exec -i immich_postgres psql -U postgres immich"
    fi
    
    # サービス再起動
    log_info "サービスを再起動中..."
    systemctl start immich jellyfin
    
    log_success "ロールバック完了"
}

# アプリケーションデプロイ
deploy_application() {
    log_info "=== アプリケーションデプロイ ==="
    
    # Gitリポジトリ更新
    if [ -d "$PROJECT_ROOT/.git" ]; then
        log_info "Gitリポジトリを更新中..."
        cd "$PROJECT_ROOT"
        git fetch origin
        git pull origin main
    fi
    
    # Docker Compose設定更新
    log_info "Docker Compose設定を確認中..."
    
    # Immichサービス更新
    if systemctl is-active --quiet immich; then
        log_info "Immichサービスを更新中..."
        systemctl stop immich
        cd "$PROJECT_ROOT"
        docker compose -f docker/immich/docker-compose.yml pull
        systemctl start immich
    fi
    
    # Jellyfinサービス更新
    if systemctl is-active --quiet jellyfin; then
        log_info "Jellyfinサービスを更新中..."
        systemctl stop jellyfin
        cd "$PROJECT_ROOT"
        docker compose -f docker/jellyfin/docker-compose.yml pull
        systemctl start jellyfin
    fi
    
    log_success "アプリケーションデプロイ完了"
}

# デプロイ後検証
verify_deployment() {
    log_info "=== デプロイ後検証 ==="
    
    # サービス状態確認
    local services=("docker" "immich" "jellyfin")
    local failed_services=()
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log_success "サービス確認: $service (正常動作)"
        else
            log_error "サービス確認: $service (動作異常)"
            failed_services+=("$service")
        fi
    done
    
    # Docker コンテナ状態確認
    log_info "Docker コンテナ状態:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    # ヘルスチェック
    log_info "ヘルスチェック実行中..."
    
    # Immich ヘルスチェック
    if curl -f http://localhost:2283/api/server-info/ping >/dev/null 2>&1; then
        log_success "Immich ヘルスチェック: OK"
    else
        log_error "Immich ヘルスチェック: 失敗"
        failed_services+=("immich-health")
    fi
    
    # Jellyfin ヘルスチェック
    if curl -f http://localhost:8096/health >/dev/null 2>&1; then
        log_success "Jellyfin ヘルスチェック: OK"
    else
        log_error "Jellyfin ヘルスチェック: 失敗"
        failed_services+=("jellyfin-health")
    fi
    
    # 結果判定
    if [ ${#failed_services[@]} -eq 0 ]; then
        log_success "デプロイ後検証: 全て正常"
        return 0
    else
        log_error "デプロイ後検証: 以下のサービスで問題が検出されました: ${failed_services[*]}"
        return 1
    fi
}

# メイン処理
main() {
    local create_backup=false
    local perform_rollback_action=false
    local verify_only=false
    local dry_run=false
    local force=false
    
    # 引数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            --backup)
                create_backup=true
                ;;
            --rollback)
                perform_rollback_action=true
                ;;
            --verify)
                verify_only=true
                ;;
            --dry-run)
                dry_run=true
                ;;
            --force)
                force=true
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                log_error "不明なオプション: $1"
                show_usage
                exit 1
                ;;
        esac
        shift
    done
    
    log_info "=== 本番デプロイスクリプト開始 ==="
    
    # ロールバック処理
    if [ "$perform_rollback_action" = "true" ]; then
        perform_rollback
        exit 0
    fi
    
    # 検証のみ
    if [ "$verify_only" = "true" ]; then
        verify_deployment
        exit $?
    fi
    
    # ドライラン
    if [ "$dry_run" = "true" ]; then
        log_info "=== ドライラン: 以下の処理が実行されます ==="
        echo "1. デプロイ前チェック"
        echo "2. バックアップ作成 (--backup指定時)"
        echo "3. アプリケーションデプロイ"
        echo "4. デプロイ後検証"
        exit 0
    fi
    
    # デプロイ実行確認
    if [ "$force" != "true" ]; then
        log_warning "本番環境にデプロイを実行します"
        if ! confirm_action "続行しますか？"; then
            log_info "デプロイをキャンセルしました"
            exit 0
        fi
    fi
    
    # デプロイ処理実行
    pre_deploy_check
    
    if [ "$create_backup" = "true" ]; then
        create_backup
    fi
    
    deploy_application
    
    if verify_deployment; then
        log_success "=== デプロイ完了 ==="
    else
        log_error "=== デプロイで問題が発生しました ==="
        if [ "$create_backup" = "true" ]; then
            log_info "ロールバックする場合: $0 --rollback"
        fi
        exit 1
    fi
}

# スクリプト実行
main "$@"
