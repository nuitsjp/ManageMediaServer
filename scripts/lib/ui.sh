#!/bin/bash
# ユーザーインターフェース・表示機能ライブラリ

# ヘルプ表示（汎用）
show_help() {
    cat << EOF
家庭用メディアサーバー自動セットアップスクリプト

使用法:
    $0 [オプション]

オプション:
    --help, -h      このヘルプを表示
    --debug         デバッグモード（詳細ログ表示）
    --force         既存設定を強制上書き
    --dry-run       実際の実行は行わず、実行予定の処理のみ表示

説明:
    このスクリプトは実行環境を自動判定し、適切なセットアップを実行します：
    - WSL環境: 開発環境として構築
    - Ubuntu Server: 本番環境として構築

例:
    ./auto-setup.sh                # 標準セットアップ
    ./auto-setup.sh --debug        # デバッグモードでセットアップ
    ./auto-setup.sh --dry-run      # 実行予定の処理を確認
EOF
}

# 環境情報表示
show_environment_info() {
    local env_type=$1
    
    log_info "=== 環境情報 ==="
    
    case "$env_type" in
        "dev")
            cat << EOF
検出環境: 開発環境（WSL）
OS: $(grep -E "(Microsoft|WSL)" /proc/version 2>/dev/null | head -1)
セットアップ対象:
  - PROJECT_ROOT: $PROJECT_ROOT
  - DATA_ROOT: $DATA_ROOT  
  - BACKUP_ROOT: $BACKUP_ROOT
  - Docker CE (WSL内ネイティブ)
  - Immich（開発用設定）
  - Jellyfin（開発用設定）
  - rclone（テスト設定）
EOF
            ;;
        "prod")
            cat << EOF
検出環境: 本番環境（Ubuntu Server）
OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
セットアップ対象:
  - PROJECT_ROOT: $PROJECT_ROOT
  - DATA_ROOT: $DATA_ROOT
  - BACKUP_ROOT: $BACKUP_ROOT
  - システムサービス
  - セキュリティ設定
  - ファイアウォール設定
EOF
            ;;
        *)
            log_warning "未対応の環境です。手動セットアップが必要です。"
            log_info "対応環境: WSL2 (Ubuntu) / Ubuntu Server 24.04 LTS"
            ;;
    esac
}

# 確認アクション（既存のcommon.shから移動される可能性のある関数）
confirm_action() {
    local message=$1
    echo -n "$message (y/N): "
    read -r response
    case "$response" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 完了メッセージ・次のステップ表示
show_completion_message() {
    local env_type=$1
    
    log_success "=== セットアップ完了 ==="
    
    case "$env_type" in
        "dev")
            show_development_next_steps
            ;;
        "prod")
            show_production_next_steps
            ;;
    esac
}

# 開発環境用の次のステップ案内
show_development_next_steps() {
    cat << EOF

次のステップ（開発環境）:
1. サービス起動:
   cd $PROJECT_ROOT
   docker compose -f docker/immich/docker-compose.yml up -d
   docker compose -f docker/jellyfin/docker-compose.yml up -d

2. ブラウザでアクセス:
   - Immich: http://localhost:2283
   - Jellyfin: http://localhost:8096

3. 開発用スクリプト:
   - サービス開始: ./scripts/dev/start-services.sh
   - サービス停止: ./scripts/dev/stop-services.sh
   - データリセット: ./scripts/dev/reset-dev-data.sh

4. 設定確認・検証:
   ./scripts/setup/verify-setup.sh

詳細は docs/setup/development-environment.md を参照してください。
EOF
}

# 本番環境用の次のステップ案内
show_production_next_steps() {
    cat << EOF

次のステップ（本番環境）:
1. rclone設定（クラウドストレージ連携）:
   rclone config

2. サービス起動:
   sudo systemctl start immich
   sudo systemctl start jellyfin

3. サービス状態確認:
   sudo systemctl status immich
   sudo systemctl status jellyfin

4. ヘルスチェック実行:
   ./scripts/monitoring/health-check.sh

5. 外部アクセス設定（必要に応じて）:
   - Cloudflare Tunnel設定
   - ファイアウォール設定確認

6. バックアップ設定:
   ./scripts/backup/manual-backup.sh

詳細は docs/operations/README.md を参照してください。
EOF
}

# システム状態サマリー表示
show_system_status() {
    local env_type=$(detect_environment)
    
    log_info "=== システム状態サマリー ==="
    
    # 基本情報
    echo "環境: $env_type"
    echo "プロジェクトルート: $PROJECT_ROOT"
    echo "データルート: $DATA_ROOT"
    echo "バックアップルート: $BACKUP_ROOT"
    echo ""
    
    # Docker状態
    if command_exists docker; then
        echo "Docker: $(docker --version 2>/dev/null || echo '未インストール')"
        if docker info >/dev/null 2>&1; then
            echo "Dockerデーモン: 動作中"
        else
            echo "Dockerデーモン: 停止中"
        fi
    else
        echo "Docker: 未インストール"
    fi
    echo ""
    
    # サービス状態
    if [ "$env_type" = "prod" ]; then
        show_service_status_prod
    else
        show_service_status_dev
    fi
}

# 本番環境サービス状態表示
show_service_status_prod() {
    echo "サービス状態（systemd）:"
    local services=("docker" "immich" "jellyfin")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo "  $service: 動作中"
        else
            echo "  $service: 停止中"
        fi
    done
}

# 開発環境サービス状態表示
show_service_status_dev() {
    echo "サービス状態（Docker Compose）:"
    
    # Immichコンテナ確認
    if docker ps --format "{{.Names}}" | grep -q "immich"; then
        echo "  Immich: 動作中"
    else
        echo "  Immich: 停止中"
    fi
    
    # Jellyfinコンテナ確認
    if docker ps --format "{{.Names}}" | grep -q "jellyfin"; then
        echo "  Jellyfin: 動作中"
    else
        echo "  Jellyfin: 停止中"
    fi
}

# サービス起動ガイド表示
show_startup_guide() {
    local env_type=$(detect_environment)
    
    log_info "=== サービス起動ガイド ==="
    
    if [ "$env_type" = "dev" ]; then
        show_development_startup_guide
    else
        show_production_startup_guide
    fi
}

# 開発環境起動ガイド
show_development_startup_guide() {
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

便利なスクリプト:
- 開始: ./scripts/dev/start-services.sh
- 停止: ./scripts/dev/stop-services.sh
EOF
}

# 本番環境起動ガイド
show_production_startup_guide() {
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

4. 自動起動設定:
   sudo systemctl enable immich
   sudo systemctl enable jellyfin

5. サービス停止:
   sudo systemctl stop immich
   sudo systemctl stop jellyfin
EOF
}

# トラブルシューティング情報表示
show_troubleshooting_info() {
    log_info "=== トラブルシューティング情報 ==="
    
    cat << EOF
よくある問題と解決方法:

1. Dockerが起動しない:
   - WSL環境: Docker Desktopを起動してください
   - Linux環境: sudo systemctl start docker

2. 権限エラー:
   - Docker権限: sudo usermod -aG docker \$USER && newgrp docker
   - ディレクトリ権限: sudo chown -R \$USER:\$USER $DATA_ROOT

3. ポートが使用中:
   - ポート確認: netstat -tuln | grep -E ":(2283|8096)"
   - プロセス終了: sudo fuser -k 2283/tcp 8096/tcp

4. コンテナが起動しない:
   - ログ確認: docker compose logs [サービス名]
   - 設定確認: ./scripts/setup/verify-setup.sh

5. 設定ファイルエラー:
   - 設定再生成: 設定ファイルを削除して再セットアップ
   - 権限確認: ls -la docker/*/docker-compose.yml

6. ディスク容量不足:
   - 使用量確認: df -h
   - Docker整理: docker system prune -f

詳細なトラブルシューティングについては、
docs/operations/troubleshooting.md を参照してください。
EOF
}

# エラー処理とリカバリー提案
show_error_recovery() {
    local error_type=$1
    local error_details=${2:-""}
    
    log_error "エラーが発生しました: $error_type"
    
    if [ -n "$error_details" ]; then
        log_info "詳細: $error_details"
    fi
    
    echo ""
    log_info "=== 復旧手順 ==="
    
    case "$error_type" in
        "docker")
            show_docker_recovery
            ;;
        "permission")
            show_permission_recovery
            ;;
        "network")
            show_network_recovery
            ;;
        "service")
            show_service_recovery
            ;;
        *)
            show_general_recovery
            ;;
    esac
}

# Docker関連エラーの復旧手順
show_docker_recovery() {
    cat << EOF
Docker関連エラーの復旧手順:

1. Dockerデーモン状態確認:
   sudo systemctl status docker

2. Dockerサービス再起動:
   sudo systemctl restart docker

3. Docker権限確認・追加:
   sudo usermod -aG docker \$USER
   newgrp docker

4. WSL環境の場合:
   - Docker Desktopを再起動
   - WSL再起動: wsl --shutdown

5. 設定ファイル確認:
   ./scripts/setup/verify-setup.sh --fix-docker
EOF
}

# 権限関連エラーの復旧手順
show_permission_recovery() {
    cat << EOF
権限関連エラーの復旧手順:

1. ディレクトリ権限修正:
   sudo chown -R \$USER:\$USER $DATA_ROOT
   sudo chown -R \$USER:\$USER $PROJECT_ROOT

2. Docker権限確認:
   groups | grep docker

3. mediaserverユーザー権限確認:
   sudo usermod -aG docker,sudo mediaserver

4. 設定ファイル権限:
   chmod 644 docker/*/docker-compose.yml
   chmod 600 config/env/*.env
EOF
}

# ネットワーク関連エラーの復旧手順
show_network_recovery() {
    cat << EOF
ネットワーク関連エラーの復旧手順:

1. ポート使用状況確認:
   netstat -tuln | grep -E ":(2283|8096)"

2. ファイアウォール設定確認:
   sudo ufw status

3. Dockerネットワーク確認:
   docker network ls
   docker network inspect bridge

4. プロセス終了（必要な場合）:
   sudo fuser -k 2283/tcp
   sudo fuser -k 8096/tcp
EOF
}

# サービス関連エラーの復旧手順
show_service_recovery() {
    cat << EOF
サービス関連エラーの復旧手順:

1. サービス状態確認:
   sudo systemctl status immich jellyfin

2. ログ確認:
   journalctl -u immich -since "10 minutes ago"
   journalctl -u jellyfin -since "10 minutes ago"

3. サービス再起動:
   sudo systemctl restart immich
   sudo systemctl restart jellyfin

4. 設定ファイル確認:
   ./scripts/setup/verify-setup.sh
EOF
}

# 一般的な復旧手順
show_general_recovery() {
    cat << EOF
一般的な復旧手順:

1. システム状態確認:
   ./scripts/monitoring/health-check.sh --detailed

2. ログ確認:
   sudo journalctl --priority=err --since "1 hour ago"

3. セットアップ検証:
   ./scripts/setup/verify-setup.sh

4. 設定の再作成:
   設定ファイルを削除して ./auto-setup.sh を再実行

5. サポート情報収集:
   ./scripts/monitoring/health-check.sh --json
EOF
}

# プログレス表示（処理中のステップ表示）
show_progress() {
    local step=$1
    local total_steps=$2
    local description=$3
    
    local percentage=$((step * 100 / total_steps))
    local bar_length=30
    local filled_length=$((percentage * bar_length / 100))
    
    printf "\r[INFO] "
    printf "["
    for ((i=0; i<bar_length; i++)); do
        if [ $i -lt $filled_length ]; then
            printf "="
        else
            printf " "
        fi
    done
    printf "] %d%% (%d/%d) %s" "$percentage" "$step" "$total_steps" "$description"
    
    if [ "$step" -eq "$total_steps" ]; then
        echo ""
    fi
}

# 設定情報サマリー表示
show_configuration_summary() {
    log_info "=== 設定情報サマリー ==="
    
    echo "プロジェクト設定:"
    echo "  PROJECT_ROOT: $PROJECT_ROOT"
    echo "  DATA_ROOT: $DATA_ROOT"
    echo "  BACKUP_ROOT: $BACKUP_ROOT"
    echo ""
    
    echo "アプリケーション設定:"
    echo "  Immich URL: http://localhost:2283"
    echo "  Jellyfin URL: http://localhost:8096"
    echo ""
    
    echo "重要なディレクトリ:"
    echo "  Immichデータ: $DATA_ROOT/immich"
    echo "  Jellyfinデータ: $DATA_ROOT/jellyfin"
    echo "  設定ファイル: $DATA_ROOT/config"
    echo "  バックアップ: $BACKUP_ROOT"
    echo ""
    
    echo "実行コマンド参考:"
    echo "  ヘルスチェック: ./scripts/monitoring/health-check.sh"
    echo "  設定確認: ./scripts/setup/verify-setup.sh"
    echo "  システム更新: ./scripts/maintenance/update-system.sh"
}

# 実行確認メッセージ（重要な操作前）
show_execution_warning() {
    local operation=$1
    local env_type=$(detect_environment)
    
    echo ""
    log_warning "=========================================="
    log_warning "   重要: $operation を実行します"
    log_warning "=========================================="
    echo ""
    echo "環境: $env_type"
    echo "対象パス: $PROJECT_ROOT"
    echo ""
    
    if [ "$env_type" = "prod" ]; then
        log_warning "本番環境での操作です。慎重に実行してください。"
    fi
    
    echo ""
}
