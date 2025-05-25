#!/bin/bash
# セットアップ検証スクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/env-loader.sh" || log_error "env-loader.sh の読み込みに失敗"

# 環境変数読み込み
load_environment

# Docker状態確認
check_docker_status() {
    log_info "=== Docker状態確認 ==="
    
    if ! command_exists docker; then
        log_error "Docker がインストールされていません"
        return 1
    fi
    
    log_info "Docker バージョン: $(docker --version)"
    
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker デーモンが起動していません"
        log_info "起動コマンド: sudo systemctl start docker"
        return 1
    fi
    
    log_success "Docker は正常に動作しています"
}

# Docker Compose確認
check_docker_compose() {
    log_info "=== Docker Compose確認 ==="
    
    if ! command_exists docker-compose; then
        log_error "docker-compose がインストールされていません"
        return 1
    fi
    
    log_info "docker-compose バージョン: $(docker-compose --version)"
    log_success "docker-compose は利用可能です"
}

# 設定ファイル確認
check_config_files() {
    log_info "=== 設定ファイル確認 ==="
    
    local env_type=$(detect_environment)
    
    # .envファイル確認
    local immich_env="$PROJECT_ROOT/docker/immich/.env"
    local jellyfin_env="$PROJECT_ROOT/docker/jellyfin/.env"
    
    if [ -f "$immich_env" ]; then
        log_success "Immich .env ファイル存在: $immich_env"
        log_debug "内容プレビュー:"
        head -5 "$immich_env" | sed 's/^/  /'
    else
        log_error "Immich .env ファイルが見つかりません: $immich_env"
    fi
    
    if [ -f "$jellyfin_env" ]; then
        log_success "Jellyfin .env ファイル存在: $jellyfin_env"
        log_debug "内容プレビュー:"
        head -5 "$jellyfin_env" | sed 's/^/  /'
    else
        log_error "Jellyfin .env ファイルが見つかりません: $jellyfin_env"
    fi
    
    # Docker Composeファイル確認（統一パス構成）
    local compose_files=(
        "$PROJECT_ROOT/docker/immich/docker-compose.yml"
        "$PROJECT_ROOT/docker/jellyfin/docker-compose.yml"
    )
    
    for compose_file in "${compose_files[@]}"; do
        if [ -f "$compose_file" ]; then
            log_success "Docker Compose ファイル存在: $compose_file"
        else
            log_warning "Docker Compose ファイルが見つかりません: $compose_file"
        fi
    done
    
    # 環境別設定ファイル確認
    local env_config_file="$PROJECT_ROOT/config/env/${env_type}.env"
    if [ -f "$env_config_file" ]; then
        log_success "環境設定ファイル存在: $env_config_file"
        log_debug "環境変数プレビュー:"
        head -3 "$env_config_file" | sed 's/^/  /'
    else
        log_warning "環境設定ファイルが見つかりません: $env_config_file"
    fi
}

# ディレクトリ構造確認
check_directories() {
    log_info "=== ディレクトリ構造確認 ==="
    
    local required_dirs=(
        "$DATA_ROOT"
        "$BACKUP_ROOT"
        "$DATA_ROOT/immich"
        "$DATA_ROOT/jellyfin/config"
        "$DATA_ROOT/jellyfin/movies"
        "$DATA_ROOT/config/rclone"
        "$DATA_ROOT/temp"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [ -d "$dir" ]; then
            log_success "ディレクトリ存在: $dir"
            log_debug "権限: $(ls -ld "$dir" | awk '{print $1, $3, $4}')"
        else
            log_error "ディレクトリが見つかりません: $dir"
        fi
    done
}

# コンテナ状態確認
check_container_status() {
    log_info "=== コンテナ状態確認 ==="
    
    # Docker権限チェック
    if ! docker ps >/dev/null 2>&1; then
        log_error "Docker コマンドの実行権限がありません"
        log_info "解決方法:"
        log_info "  1. sudo usermod -aG docker $USER"
        log_info "  2. newgrp docker (または再ログイン)"
        log_info "  3. sudo systemctl restart docker"
        return 1
    fi
    
    # 実行中のコンテナ一覧
    if docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep -E "(immich|jellyfin)" >/dev/null 2>&1; then
        log_info "実行中のコンテナ:"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(immich|jellyfin)" | sed 's/^/  /'
        log_success "コンテナが実行中です"
    else
        log_warning "immich/jellyfinコンテナが実行されていません"
        
        # 停止中のコンテナも確認
        if docker ps -a --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep -E "(immich|jellyfin)" >/dev/null 2>&1; then
            log_info "停止中のコンテナ:"
            docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep -E "(immich|jellyfin)" | sed 's/^/  /'
            log_info "コンテナを起動する場合は --start-containers オプションを使用してください"
        else
            log_error "immich/jellyfinコンテナが見つかりません"
            log_info "Docker Composeでコンテナを作成してください"
            log_info "自動作成・起動する場合は --start-containers オプションを使用してください"
        fi
    fi
    
    # 全コンテナ表示（デバッグ用）
    if [ "${DEBUG:-0}" = "1" ]; then
        log_debug "全コンテナ一覧:"
        docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null | head -10 | sed 's/^/  /'
    fi
}

# ポート確認
check_ports() {
    log_info "=== ポート確認 ==="
    
    local ports=("2283:Immich" "8096:Jellyfin")
    
    for port_service in "${ports[@]}"; do
        local port=$(echo "$port_service" | cut -d: -f1)
        local service=$(echo "$port_service" | cut -d: -f2)
        
        if netstat -tuln 2>/dev/null | grep ":$port " >/dev/null; then
            log_success "$service ポート $port でリッスン中"
        elif ss -tuln 2>/dev/null | grep ":$port " >/dev/null; then
            log_success "$service ポート $port でリッスン中"
        else
            log_warning "$service ポート $port でリッスンしていません"
        fi
    done
}

# ネットワーク接続テスト
check_network_connectivity() {
    log_info "=== ネットワーク接続テスト ==="
    
    local services=(
        "http://localhost:2283:Immich"
        "http://localhost:8096:Jellyfin"
    )
    
    for service_url in "${services[@]}"; do
        local url=$(echo "$service_url" | cut -d: -f1,2,3)
        local service_name=$(echo "$service_url" | cut -d: -f4)
        
        if curl -s --connect-timeout 5 "$url" >/dev/null 2>&1; then
            log_success "$service_name ($url) 接続成功"
        else
            log_warning "$service_name ($url) 接続失敗"
            log_info "手動確認: curl -I $url"
        fi
    done
}

# サービス起動ガイド
show_startup_guide() {
    log_info "=== サービス起動ガイド ==="
    
    local env_type=$(detect_environment)
    
    if [ "$env_type" = "dev" ]; then
        cat << EOF
開発環境でのサービス起動方法:

1. Docker権限確認・設定:
   sudo usermod -aG docker $USER
   newgrp docker

2. プロジェクトルートに移動:
   cd $PROJECT_ROOT

3. 個別サービス起動:
   docker compose -f docker/immich/docker-compose.yml up -d
   docker compose -f docker/jellyfin/docker-compose.yml up -d

4. または統合起動（今後実装予定）:
   # docker compose -f docker/dev-compose.yml up -d

5. ログ確認:
   docker compose -f docker/immich/docker-compose.yml logs -f
   docker compose -f docker/jellyfin/docker-compose.yml logs -f

6. サービス停止:
   docker compose -f docker/immich/docker-compose.yml down
   docker compose -f docker/jellyfin/docker-compose.yml down

現在の問題:
EOF
        # 問題点を特定して表示
        local missing_files=()
        if [ ! -f "$PROJECT_ROOT/docker/immich/docker-compose.yml" ]; then
            missing_files+=("docker/immich/docker-compose.yml")
        fi
        if [ ! -f "$PROJECT_ROOT/docker/jellyfin/docker-compose.yml" ]; then
            missing_files+=("docker/jellyfin/docker-compose.yml")
        fi
        
        if [ ${#missing_files[@]} -gt 0 ]; then
            echo "  - Docker Composeファイルが存在しません:"
            for file in "${missing_files[@]}"; do
                echo "    $PROJECT_ROOT/$file"
            done
        fi
        
        if ! docker ps >/dev/null 2>&1; then
            echo "  - Docker権限がありません"
            echo "    解決: sudo usermod -aG docker $USER && newgrp docker"
        fi
    else
        cat << EOF
本番環境でのサービス起動方法:

1. systemdサービス起動:
   sudo systemctl start immich
   sudo systemctl start jellyfin

2. サービス状態確認:
   sudo systemctl status immich
   sudo systemctl status jellyfin

3. ログ確認:
   journalctl -u immich -f
   journalctl -u jellyfin -f
EOF
    fi
}

# トラブルシューティング情報
show_troubleshooting() {
    log_info "=== トラブルシューティング ==="
    
    cat << EOF
よくある問題と解決方法:

1. Docker権限エラー:
   - 原因: ユーザーがdockerグループに属していない
   - 解決: sudo usermod -aG docker $USER && newgrp docker
   - 確認: docker ps (権限エラーが出なければOK)

2. Docker Composeファイルが見つからない:
   - 確認: ls -la $PROJECT_ROOT/docker/immich/
   - 確認: ls -la $PROJECT_ROOT/docker/jellyfin/
   - 作成: テンプレートから各ディレクトリのdocker-compose.ymlを作成

3. 環境設定ファイルが見つからない:
   - 確認: ls -la $PROJECT_ROOT/config/env/
   - 作成: config/env/dev.env または config/env/prod.env

4. ブラウザからアクセスできない場合:
   - ポート確認: netstat -tuln | grep -E "(2283|8096)"
   - ファイアウォール確認: sudo ufw status
   - コンテナログ確認: docker logs [コンテナ名]

5. Docker関連の問題:
   - Docker起動: sudo systemctl start docker
   - Docker再起動: sudo systemctl restart docker
   - Docker状態確認: sudo systemctl status docker

6. 設定ファイルの問題:
   - .envファイル再生成: auto-setup.sh --force

7. ディレクトリ権限の問題:
   - 権限修正: sudo chown -R \$USER:\$USER $DATA_ROOT

現在の環境状態:
- 環境: $(detect_environment)
- Dockerグループ: $(groups | grep -o docker || echo "なし")
- Docker権限: $(docker ps >/dev/null 2>&1 && echo "OK" || echo "エラー")

設計方針に基づく構成:
- Docker設定: docker/immich/, docker/jellyfin/ (環境共通)
- 環境設定: config/env/dev.env, config/env/prod.env
- データ: \$DATA_ROOT (環境変数で指定)

詳細ログは以下で確認:
   export DEBUG=1
   ./verify-setup.sh
EOF
}

# Docker Composeファイル確認・バリデーション
validate_docker_compose_files() {
    log_info "=== Docker Composeファイルバリデーション ==="
    
    local compose_files=(
        "$PROJECT_ROOT/docker/immich/docker-compose.yml"
        "$PROJECT_ROOT/docker/jellyfin/docker-compose.yml"
    )
    
    for compose_file in "${compose_files[@]}"; do
        if [ -f "$compose_file" ]; then
            log_info "検証中: $(basename "$(dirname "$compose_file")")"
            
            # docker-compose config でバリデーション
            if (cd "$(dirname "$compose_file")" && docker-compose config >/dev/null 2>&1); then
                log_success "設定ファイル有効: $compose_file"
            else
                log_warning "設定ファイルに問題があります: $compose_file"
                log_info "詳細確認: cd $(dirname "$compose_file") && docker-compose config"
            fi
        else
            log_warning "ファイルが見つかりません: $compose_file"
        fi
    done
}

# コンテナ起動機能
start_containers() {
    log_info "=== コンテナ起動 ==="
    
    local compose_files=(
        "$PROJECT_ROOT/docker/immich/docker-compose.yml"
        "$PROJECT_ROOT/docker/jellyfin/docker-compose.yml"
    )
    
    for compose_file in "${compose_files[@]}"; do
        if [ -f "$compose_file" ]; then
            local service_name=$(basename "$(dirname "$compose_file")")
            log_info "${service_name} コンテナを起動中..."
            
            if (cd "$(dirname "$compose_file")" && docker-compose up -d); then
                log_success "${service_name} コンテナ起動完了"
            else
                log_error "${service_name} コンテナ起動に失敗しました"
                log_info "ログ確認: cd $(dirname "$compose_file") && docker-compose logs"
            fi
        else
            log_error "Docker Composeファイルが見つかりません: $compose_file"
        fi
    done
    
    # 起動待機
    log_info "サービス起動を待機中..."
    sleep 10
    
    # 再度状態確認
    check_container_status
    check_ports
    check_network_connectivity
}

# メイン処理
main() {
    local show_guide=false
    local show_troubleshooting=false
    local start_containers_flag=false
    
    # 引数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            --debug)
                export DEBUG=1
                ;;
            --guide)
                show_guide=true
                ;;
            --troubleshooting)
                show_troubleshooting=true
                ;;
            --start-containers)
                start_containers_flag=true
                ;;
            --help|-h)
                cat << EOF
セットアップ検証スクリプト

使用法:
    $0 [オプション]

オプション:
    --debug              デバッグモード
    --guide              起動ガイドを表示
    --troubleshooting    トラブルシューティング情報を表示
    --start-containers   コンテナを自動起動
    --help, -h           このヘルプを表示
EOF
                exit 0
                ;;
            *)
                log_error "不明なオプション: $1"
                exit 1
                ;;
        esac
        shift
    done
    
    log_info "=== セットアップ検証開始 ==="
    log_info "環境: $(detect_environment)"
    log_info "PROJECT_ROOT: $PROJECT_ROOT"
    log_info "DATA_ROOT: $DATA_ROOT"
    echo
    
    # 基本的な確認
    check_docker_status
    check_docker_compose  
    check_config_files
    check_directories
    validate_docker_compose_files
    check_container_status
    
    # コンテナ起動オプション
    if [ "$start_containers_flag" = "true" ]; then
        start_containers
    else
        check_ports
        check_network_connectivity
    fi
    
    if [ "$show_guide" = "true" ]; then
        show_startup_guide
    fi
    
    if [ "$show_troubleshooting" = "true" ]; then
        show_troubleshooting
    fi
    
    log_success "=== セットアップ検証完了 ==="
    
    # サマリー表示
    log_info "=== 確認結果サマリー ==="
    if [ "$start_containers_flag" != "true" ]; then
        log_info "次のコマンドでサービスを起動してください:"
        local env_type=$(detect_environment)
        if [ "$env_type" = "dev" ]; then
            log_info "  cd $PROJECT_ROOT"
            log_info "  docker compose -f docker/immich/docker-compose.yml up -d"
            log_info "  docker compose -f docker/jellyfin/docker-compose.yml up -d"
            log_info ""
            log_info "または自動起動: $0 --start-containers"
        else
            log_info "  sudo systemctl start immich jellyfin"
        fi
    fi
    
    log_info "詳細ガイド: $0 --guide"
    log_info "トラブルシューティング: $0 --troubleshooting"
}

# スクリプト実行
main "$@"