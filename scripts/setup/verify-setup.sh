#!/bin/bash
# セットアップ検証スクリプト
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗"
source "$SCRIPT_DIR/../lib/rclone.sh" || log_error "rclone.sh の読み込みに失敗"

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
        
        # WSL環境での自動修復を試行
        if is_wsl; then
            log_info "WSL環境でのDocker起動問題を自動修復中..."
            fix_docker_wsl_issues
        else
            log_info "起動コマンド: sudo systemctl start docker"
        fi
        return 1
    fi
    
    log_success "Docker は正常に動作しています"
}

# WSL環境でのDocker問題修復
fix_docker_wsl_issues() {
    log_info "WSL環境でのDocker問題を診断・修復中..."
    
    # containerdサービス確認
    if ! systemctl is-active --quiet containerd; then
        log_info "containerdサービスを起動中..."
        sudo systemctl start containerd
    fi
    
    # Docker設定ファイル確認
    local docker_config="/etc/docker/daemon.json"
    if [ ! -f "$docker_config" ]; then
        log_info "WSL用Docker設定ファイルを作成中..."
        sudo mkdir -p /etc/docker
        sudo tee "$docker_config" > /dev/null << 'EOF'
{
    "hosts": ["fd://"],
    "iptables": false
}
EOF
    fi
    
    # systemd override設定
    local override_dir="/etc/systemd/system/docker.service.d"
    local override_file="$override_dir/override.conf"
    
    if [ ! -f "$override_file" ]; then
        log_info "systemd override設定を作成中..."
        sudo mkdir -p "$override_dir"
        sudo tee "$override_file" > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --containerd=/run/containerd/containerd.sock
EOF
        sudo systemctl daemon-reload
    fi
    
    # Docker再起動試行
    log_info "Dockerサービスを再起動中..."
    if sudo systemctl restart docker; then
        sleep 3
        if docker info >/dev/null 2>&1; then
            log_success "Docker修復に成功しました"
            return 0
        fi
    fi
    
    # 手動起動試行
    log_warning "systemctlでの起動に失敗。手動起動を試行中..."
    sudo pkill dockerd 2>/dev/null || true
    sleep 2
    
    sudo /usr/bin/dockerd --host=fd:// --containerd=/run/containerd/containerd.sock &
    sleep 5
    
    if docker info >/dev/null 2>&1; then
        log_success "Docker手動起動に成功しました"
        log_warning "次回ログイン時にも起動するよう .bashrc に設定を追加することを推奨します"
    else
        log_error "Docker起動修復に失敗しました"
        show_docker_troubleshooting
    fi
}

# Docker トラブルシューティング表示
show_docker_troubleshooting() {
    log_info "=== Docker トラブルシューティング ==="
    
    cat << EOF
WSL環境でのDocker問題解決方法:

1. Windows側でDocker Desktopを使用する場合:
   - Docker Desktop for Windowsをインストール
   - WSL 2 Integrationを有効化
   - この場合、WSL内でのDockerインストールは不要

2. WSL内でネイティブDockerを使用する場合:
   以下を順番に実行:
   
   a) containerdサービス確認:
   sudo systemctl status containerd
   sudo systemctl start containerd
   
   b) Docker設定確認:
   sudo cat /etc/docker/daemon.json
   
   c) Docker手動起動:
   sudo dockerd --host=fd:// --containerd=/run/containerd/containerd.sock &
   
   d) 権限確認:
   sudo usermod -aG docker $USER
   newgrp docker

3. 永続的な解決方法:
   ~/.bashrc に以下を追加:
   
   # Docker自動起動 (WSL)
   if ! docker info >/dev/null 2>&1; then
       sudo service docker start >/dev/null 2>&1
   fi

4. Windows側の設定確認:
   - WSL 2が有効になっているか確認
   - Windows版Dockerとの競合確認

現在の状態:
- containerd: $(systemctl is-active containerd 2>/dev/null || echo "不明")
- docker.service: $(systemctl is-active docker 2>/dev/null || echo "不明")
- Dockerプロセス: $(pgrep dockerd >/dev/null && echo "実行中" || echo "停止中")

ログ確認:
   sudo journalctl -xeu docker.service
   sudo journalctl -xeu containerd.service
EOF
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
    
    # Immich .envファイル確認
    local immich_env="$PROJECT_ROOT/docker/immich/.env"
    
    if [ -f "$immich_env" ]; then
        log_success "Immich .env ファイル存在: $immich_env"
        log_debug "内容プレビュー:"
        head -5 "$immich_env" | sed 's/^/  /'
    else
        log_error "Immich .env ファイルが見つかりません: $immich_env"
    fi
    
    # Jellyfin設定確認（.env不要）
    log_info "Jellyfin設定: 公式Docker Composeファイルを使用（.env不要）"
    
    # Docker Composeファイル確認（統一パス構成）
    local compose_files=(
        "$PROJECT_ROOT/docker/immich/docker-compose.yml"
        "$PROJECT_ROOT/docker/jellyfin/docker-compose.yml"
    )
    
    for compose_file in "${compose_files[@]}"; do
        if [ -f "$compose_file" ]; then
            log_success "Docker Compose ファイル存在: $compose_file"
            
            # Jellyfinの場合は公式ファイル使用を明記
            if [[ "$compose_file" == *"jellyfin"* ]]; then
                log_info "Jellyfin: 公式Docker Composeファイル使用"
            fi
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

4. ログ確認:
   docker compose -f docker/immich/docker-compose.yml logs -f
   docker compose -f docker/jellyfin/docker-compose.yml logs -f

5. サービス停止:
   docker compose -f docker/immich/docker-compose.yml down
   docker compose -f docker/jellyfin/docker-compose.yml down

設定について:
- Immich: .envファイルで設定管理
- Jellyfin: 公式docker-compose.ymlを直接編集

現在の問題:
EOF
        # 問題点を特定して表示
        local missing_files=()
        if [ ! -f "$PROJECT_ROOT/docker/immich/docker-compose.yml" ]; then
            missing_files+=("docker/immich/docker-compose.yml")
        fi
        if [ ! -f "$PROJECT_ROOT/docker/jellyfin/docker-compose.yml" ]; then
            missing_files+=("docker/jellyfin/docker-compose.yml（公式ファイル）")
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
   - Immich: 自動生成されるdocker-compose.yml + .env
   - Jellyfin: 公式docker-compose.ymlを手動配置（.env不要）
   - 確認: ls -la $PROJECT_ROOT/docker/immich/
   - 確認: ls -la $PROJECT_ROOT/docker/jellyfin/

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
   - Immich .envファイル再生成: auto-setup.sh --force
   - Jellyfin設定変更: docker/jellyfin/docker-compose.yml を直接編集

7. ディレクトリ権限の問題:
   - 権限修正: sudo chown -R \$USER:\$USER $DATA_ROOT

設定ファイル構成:
- Immich: docker/immich/docker-compose.yml + .env（自動生成）
- Jellyfin: docker/jellyfin/docker-compose.yml（公式ファイル、.env不要）
- 環境設定: config/env/dev.env, config/env/prod.env
- データ: \$DATA_ROOT (環境変数で指定)

現在の環境状態:
- 環境: $(detect_environment)
- Dockerグループ: $(groups | grep -o docker || echo "なし")
- Docker権限: $(docker ps >/dev/null 2>&1 && echo "OK" || echo "エラー")

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
    local fix_docker=false
    
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
            --fix-docker)
                fix_docker=true
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
    --fix-docker         Docker起動問題を自動修復（WSL環境）
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
    
    # Docker修復オプション
    if [ "$fix_docker" = "true" ]; then
        if is_wsl; then
            fix_docker_wsl_issues
        else
            log_warning "--fix-docker オプションはWSL環境でのみ有効です"
        fi
        exit 0
    fi
    
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
            
            # Docker問題がある場合の修復案内
            if ! docker info >/dev/null 2>&1; then
                log_info ""
                log_warning "Docker起動問題の修復: $0 --fix-docker"
            fi
        else
            log_info "  sudo systemctl start immich jellyfin"
        fi
    fi
    
    log_info "詳細ガイド: $0 --guide"
    log_info "トラブルシューティング: $0 --troubleshooting"
}

# スクリプト実行
main "$@"