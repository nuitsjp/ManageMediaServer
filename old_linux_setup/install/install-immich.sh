#!/bin/bash
set -euo pipefail
#
# ImmichをDockerで設定・起動するスクリプト
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 共通ライブラリ読み込み ---
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗しました。" >&2; exit 1; }
# shellcheck source=../lib/config.sh
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗しました。"

# --- 事前チェック ---
pre_check() {
    # Docker確認
    if ! command_exists docker; then
        log_error "Dockerがインストールされていません。install-docker.sh を実行してください。"
        exit 1
    fi
    
    # Docker Compose確認
    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Composeがインストールされていません。install-docker.sh を実行してください。"
        exit 1
    fi
    
    # 設定値検証
    validate_config
}

# --- 設定値検証 ---
validate_config() {
    # 必須設定の確認
    : "${TIME_ZONE:?TIME_ZONE が未定義です。config.sh を確認してください}"
    : "${IMMICH_DIR_PATH:?IMMICH_DIR_PATH が未定義です。config.sh を確認してください}"
    
    # デフォルト値設定
    if [ -z "${IMMICH_UPLOAD_LOCATION:-}" ]; then
        IMMICH_UPLOAD_LOCATION="${IMMICH_DIR_PATH}/library"
        log_info "UPLOAD_LOCATION未設定のため、デフォルト値を使用: ${IMMICH_UPLOAD_LOCATION}"
    fi
    
    # 設定値表示
    log_info "設定確認:"
    log_info "  - 設定ディレクトリ: $IMMICH_DIR_PATH"
    log_info "  - アップロードディレクトリ: $IMMICH_UPLOAD_LOCATION"
    [ -n "${IMMICH_EXTERNAL_LIBRARY_PATH:-}" ] && \
        log_info "  - 外部ライブラリパス: $IMMICH_EXTERNAL_LIBRARY_PATH"
}

# --- インストール済みチェック ---
is_already_installed() {
    if [ -f "${IMMICH_DIR_PATH}/docker-compose.yml" ] && \
       [ -f "${IMMICH_DIR_PATH}/.env" ] && \
       docker compose -f "${IMMICH_DIR_PATH}/docker-compose.yml" ps --quiet 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

# --- 設定ファイルダウンロード ---
download_config_files() {
    log_info "設定ファイルをダウンロード中..."
    
    # docker-compose.yml
    if ! wget -qO "${IMMICH_DIR_PATH}/docker-compose.yml" \
         "https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml"; then
        log_error "docker-compose.yml のダウンロードに失敗しました"
        return 1
    fi
    log_success "docker-compose.yml をダウンロードしました"
    
    # .env
    if ! wget -qO "${IMMICH_DIR_PATH}/.env" \
         "https://github.com/immich-app/immich/releases/latest/download/example.env"; then
        log_error ".env のダウンロードに失敗しました"
        return 1
    fi
    log_success ".env をダウンロードしました"
}

# --- 環境設定更新 ---
update_env_file() {
    local env_file="${IMMICH_DIR_PATH}/.env"
    
    log_info "環境設定を更新中..."
    
    # バックアップ作成
    if [ -f "$env_file" ]; then
        cp "$env_file" "${env_file}.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # タイムゾーン設定
    if grep -qE '^\s*#?\s*TZ=' "$env_file"; then
        sed -i -E "s|^\s*#?\s*TZ=.*|TZ=${TIME_ZONE}|" "$env_file"
    else
        echo "TZ=${TIME_ZONE}" >> "$env_file"
    fi
    
    # アップロードディレクトリ設定
    if grep -qE '^\s*#?\s*UPLOAD_LOCATION=' "$env_file"; then
        sed -i -E "s|^\s*#?\s*UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${IMMICH_UPLOAD_LOCATION}|" "$env_file"
    else
        echo "UPLOAD_LOCATION=${IMMICH_UPLOAD_LOCATION}" >> "$env_file"
    fi
    
    log_success "環境設定を更新しました"
}

# --- 外部ライブラリ設定 ---
configure_external_library() {
    if [ -z "${IMMICH_EXTERNAL_LIBRARY_PATH:-}" ]; then
        return 0
    fi
    
    log_info "外部ライブラリマウントを設定中..."
    
    local compose_file="${IMMICH_DIR_PATH}/docker-compose.yml"
    local mount_line="      - ${IMMICH_EXTERNAL_LIBRARY_PATH}:/usr/src/app/external-library:ro"
    
    # 既存のマウント設定確認
    if grep -qF "$mount_line" "$compose_file"; then
        log_info "外部ライブラリマウントは既に設定済みです"
        return 0
    fi
    
    # immich-serverサービスにマウント追加
    # volumes:セクションの最後に追加
    if grep -q "immich-server:" "$compose_file"; then
        # sedで複雑な操作をするより、設定ファイルを直接編集
        # 実際の実装では、より堅牢な方法（yqなど）を使用することを推奨
        local marker='/etc/localtime:/etc/localtime:ro'
        if grep -qF "$marker" "$compose_file"; then
            sed -i "/${marker//\//\\/}/a\\${mount_line}" "$compose_file"
            log_success "外部ライブラリマウントを追加しました"
        else
            log_warning "マウント設定の挿入位置が見つかりません。手動で設定してください"
        fi
    fi
}

# --- Immichサービス起動 ---
start_immich_services() {
    log_info "Dockerイメージをプル中..."
    if ! docker compose pull; then
        log_error "Dockerイメージのプルに失敗しました"
        return 1
    fi
    
    log_info "Immichサービスを起動中..."
    if ! docker compose up -d; then
        log_error "サービスの起動に失敗しました"
        return 1
    fi
    
    # サービス起動待機
    log_info "サービスの起動を待機中..."
    local max_wait=60
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        if docker compose ps --format json | jq -e '.[] | select(.State == "running")' >/dev/null 2>&1; then
            log_success "Immichサービスが起動しました"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        echo -n "."
    done
    
    log_error "サービスの起動がタイムアウトしました"
    return 1
}

# --- インストール確認 ---
verify_installation() {
    log_info "Immichの動作確認中..."
    
    # コンテナ状態確認
    local running_containers=$(docker compose ps --format json | jq -r '.[] | select(.State == "running") | .Service' 2>/dev/null | wc -l)
    local total_containers=$(docker compose ps --format json | jq -r '.[].Service' 2>/dev/null | wc -l)
    
    if [ "$running_containers" -eq "$total_containers" ] && [ "$total_containers" -gt 0 ]; then
        log_success "全てのImmichコンテナが正常に動作しています ($running_containers/$total_containers)"
    else
        log_warning "一部のコンテナが正常に動作していません ($running_containers/$total_containers)"
        docker compose ps
    fi
    
    # ヘルスチェック（簡易版）
    local server_ip=$(hostname -I | awk '{print $1}')
    log_info "Web UIアクセス確認中..."
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:2283" | grep -q "200\|302"; then
        log_success "Web UIが正常に応答しています"
    else
        log_warning "Web UIの応答確認に失敗しました（初回起動時は時間がかかる場合があります）"
    fi
}

# --- メイン処理 ---
main() {
    log_info "=== Immich セットアップ開始 ==="
    
    # 事前チェック
    pre_check
    
    # ディレクトリ作成
    ensure_dir_exists "$IMMICH_DIR_PATH"
    ensure_dir_exists "$IMMICH_UPLOAD_LOCATION"
    [ -n "${IMMICH_EXTERNAL_LIBRARY_PATH:-}" ] && ensure_dir_exists "$IMMICH_EXTERNAL_LIBRARY_PATH"
    
    # 作業ディレクトリ移動
    cd "$IMMICH_DIR_PATH" || log_error "ディレクトリ移動失敗: $IMMICH_DIR_PATH"
    
    # 冪等性チェック
    if is_already_installed; then
        log_success "Immichは既にセットアップ済みです"
        docker compose ps
        return 0
    fi
    
    # 設定ファイルダウンロード
    download_config_files
    
    # 環境設定更新
    update_env_file
    
    # 外部ライブラリ設定
    configure_external_library
    
    # サービス起動
    start_immich_services
    
    # 動作確認
    verify_installation
    
    # 完了メッセージ
    local server_ip=$(hostname -I | awk '{print $1}')
    log_success "=== Immich セットアップ完了 ==="
    log_info ""
    log_info "アクセスURL:"
    log_info "  - Web UI: http://${server_ip}:2283"
    log_info "  - 初回アクセス時に管理者アカウントを作成してください"
    log_info ""
    log_info "サービス管理:"
    log_info "  - 停止: cd $IMMICH_DIR_PATH && docker compose down"
    log_info "  - 起動: cd $IMMICH_DIR_PATH && docker compose up -d"
    log_info "  - ログ: cd $IMMICH_DIR_PATH && docker compose logs -f"
}

# エントリーポイント
main "$@"