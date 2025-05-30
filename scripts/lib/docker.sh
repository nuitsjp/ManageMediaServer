#!/bin/bash
# Docker層ライブラリ（Docker基盤・汎用Compose管理）

# Docker CEインストール
install_docker() {
    log_info "=== Docker のインストール ==="
    
    # 冪等性チェック: 既にDockerが正常に動作している場合はスキップ
    if docker --version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        log_success "Docker は既に正常にインストール・動作しています"
        # --- ここから修正 ---
        # dockerグループがなければ作成し、ユーザーを追加
        if ! getent group docker >/dev/null; then
            log_warning "dockerグループが存在しません。作成します。"
            groupadd docker
        fi
        usermod -aG docker "$USER"
        # --- ここまで修正 ---
        return 0
    fi
    
    # 強制モードの場合は完全クリーンアップ
    cleanup_docker_completely
    
    # Dockerサービス停止（既存のプロセスがある場合）
    log_info "既存のDockerサービスを停止中..."
    systemctl stop docker || true
    pkill dockerd || true
    
    # 既存の Docker および containerd パッケージを削除して競合を回避
    log_info "既存の Docker 関連パッケージを削除中..."
    apt remove -y docker docker-engine docker.io containerd containerd.io runc || true
    
    # パッケージリスト更新
    apt update -y

    # docker.io をインストール
    local docker_pkgs=("docker.io")
    for pkg in "${docker_pkgs[@]}"; do
        if ! dpkg -l | grep -qw "$pkg"; then
            apt install -y "$pkg"
        fi
    done

    # WSL環境での追加設定
    if is_wsl; then
        setup_docker_for_wsl
    fi

    # docker グループにユーザーを追加
    usermod -aG docker "$USER"
    
    # Dockerサービス起動
    if ! systemctl start docker; then
        log_warning "systemctl でのDocker起動に失敗しました。手動起動を試行します..."
        if is_wsl; then
            # WSL環境での手動起動
            /usr/bin/dockerd --host=unix:///var/run/docker.sock --host=tcp://127.0.0.1:2375 &
            sleep 5
            if docker info >/dev/null 2>&1; then
                log_success "Docker手動起動に成功しました"
            else
                log_error "Docker起動に失敗しました。WSL設定を確認してください"
            fi
        fi
    else
        log_success "Docker サービス起動成功"
    fi
    
    # 最終動作確認（エラー時は自動停止）
    if ! docker info >/dev/null 2>&1; then
        log_error "Dockerが正常に動作していません"
        return 1
    fi
    
    log_success "Docker のインストール完了"
}

# WSL環境でのDocker設定
setup_docker_for_wsl() {
    log_info "WSL環境用Docker設定を適用中..."
    
    # Docker daemon設定ファイル作成（hostsオプションを削除）
    local docker_config_dir="/etc/docker"
    local docker_config_file="$docker_config_dir/daemon.json"
    
    ensure_dir_exists "$docker_config_dir"
    
    # WSL用Docker daemon設定（systemdと競合しないよう修正）
    cat > "$docker_config_file" << 'EOF'
{
    "iptables": false,
    "bridge": "none"
}
EOF
    
    # systemd設定をWSL用に調整（デフォルトhostsを使用）
    local systemd_override_dir="/etc/systemd/system/docker.service.d"
    ensure_dir_exists "$systemd_override_dir"
    
    cat > "$systemd_override_dir/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --containerd=/run/containerd/containerd.sock
EOF
    
    # systemd設定リロード
    systemctl daemon-reload
    
    log_success "WSL環境用Docker設定完了"
}

# Docker完全クリーンアップ（強制オプション用）
cleanup_docker_completely() {
    if [ "${FORCE:-false}" != "true" ]; then
        return 0
    fi
    
    log_warning "=== Docker完全クリーンアップを実行中 ==="
    
    # 全てのコンテナを停止・削除
    if docker ps -aq >/dev/null 2>&1; then
        log_info "全Dockerコンテナを停止・削除中..."
        docker stop $(docker ps -aq) || true
        docker rm $(docker ps -aq) || true
    fi
    
    # 全てのイメージを削除
    if docker images -q >/dev/null 2>&1; then
        log_info "全Dockerイメージを削除中..."
        docker rmi $(docker images -q) || true
    fi
    
    # 全てのボリュームを削除
    if docker volume ls -q >/dev/null 2>&1; then
        log_info "全Dockerボリュームを削除中..."
        docker volume rm $(docker volume ls -q) || true
    fi
    
    # 全てのネットワークを削除
    if docker network ls -q >/dev/null 2>&1; then
        log_info "カスタムDockerネットワークを削除中..."
        docker network prune -f || true
    fi
    
    # Docker設定ファイル削除
    rm -rf /etc/docker/daemon.json || true
    rm -rf /etc/systemd/system/docker.service.d/override.conf || true
    
    log_success "Docker完全クリーンアップ完了"
}

# Docker Compose プラグインインストール
install_docker_compose_plugin() {
    log_info "=== Docker Compose プラグインのインストール ==="
    
    # Docker Compose プラグインが既に利用可能かチェック
    if docker compose version >/dev/null 2>&1; then
        local installed_version=$(docker compose version --short 2>/dev/null || echo "unknown")
        log_success "Docker Compose プラグインは既にインストールされています (バージョン: $installed_version)"
        return 0
    fi
    
    log_info "Docker Compose プラグインをインストール中..."
    
    # Ubuntu/Debian の場合はパッケージマネージャーからインストール
    if command_exists apt; then
        # docker-compose-plugin パッケージをインストール
        if apt install -y docker-compose-plugin 2>/dev/null; then
            log_info "docker-compose-plugin パッケージをインストールしました"
        else
            log_warning "docker-compose-plugin パッケージのインストールに失敗しました。手動インストールを試行します..."
            install_docker_compose_manual
            return $?
        fi
    else
        # 手動インストール
        install_docker_compose_manual
        return $?
    fi
    
    # インストール確認
    if docker compose version >/dev/null 2>&1; then
        local installed_version=$(docker compose version --short 2>/dev/null || echo "unknown")
        log_success "Docker Compose プラグインのインストール完了 (バージョン: $installed_version)"
    else
        log_error "Docker Compose プラグインのインストールに失敗しました"
        return 1
    fi
}

# Docker Compose プラグイン手動インストール
install_docker_compose_manual() {
    log_info "Docker Compose プラグインを手動でインストールします..."
    
    # 最新バージョンのDocker Compose プラグインをダウンロード
    local compose_version
    if ! compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null); then
        log_warning "最新バージョンの取得に失敗しました。固定バージョンを使用します"
        compose_version="v2.24.0"
    fi
    
    local compose_url="https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-linux-x86_64"
    
    # Docker CLI プラグインディレクトリ作成
    local plugin_dir="/usr/local/lib/docker/cli-plugins"
    mkdir -p "$plugin_dir"
    
    # Docker Compose プラグインをダウンロード
    if curl -SL "$compose_url" -o "$plugin_dir/docker-compose"; then
        chmod +x "$plugin_dir/docker-compose"
        log_info "Docker Compose プラグインをダウンロードしました"
    else
        log_error "Docker Compose プラグインのダウンロードに失敗しました"
        return 1
    fi
    
    return 0
}
