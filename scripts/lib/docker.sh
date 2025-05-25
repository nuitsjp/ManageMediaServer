#!/bin/bash
# Docker層ライブラリ（Docker基盤・汎用Compose管理）

# Docker CEインストール
install_docker() {
    log_info "=== Docker のインストール ==="
    
    # 既存の Docker および containerd パッケージを削除して競合を回避
    log_info "既存の Docker 関連パッケージを削除中..."
    apt remove -y docker docker-engine docker.io containerd containerd.io runc || true
    
    # パッケージリスト更新
    apt update -y

    # docker.io と docker-compose をインストール
    local docker_pkgs=("docker.io" "docker-compose")
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
    
    log_success "Docker と docker-compose のインストール完了"
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

# Docker Compose構造作成
create_docker_compose_structure() {
    log_info "Docker Compose構造を準備中..."
    
    # 必要なディレクトリを作成
    local services=("immich" "jellyfin")
    
    for service in "${services[@]}"; do
        local compose_dir="$PROJECT_ROOT/docker/$service"
        ensure_dir_exists "$compose_dir"
        log_debug "Docker Compose構造を準備しました: $compose_dir"
    done
    
    log_success "Docker Compose構造の準備が完了しました"
}

# Docker検証
validate_docker_installation() {
    log_info "Docker インストールを検証中..."
    
    if ! command_exists docker; then
        log_error "Docker コマンドが見つかりません"
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker デーモンが起動していません"
    fi
    
    if ! command_exists docker-compose; then
        log_error "docker-compose コマンドが見つかりません"
    fi
    
    log_success "Docker インストールが正常に検証されました"
}
