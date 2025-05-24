#!/bin/bash
#
# ImmichをDockerで設定・起動するスクリプト
#

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# 共通ライブラリと設定ファイルを読み込む
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"   || { echo "[ERROR] common.sh の読み込みに失敗しました。" >&2; exit 1; }
# shellcheck source=../lib/config.sh
source "$SCRIPT_DIR/../lib/config.sh"   || log_error "config.sh の読み込みに失敗しました。"

# --- 事前チェック ---
command_exists docker      || log_error "Docker がインストールされていません。install-docker.sh を実行してください。"
docker compose version >/dev/null 2>&1 || log_error "Docker Compose がインストールされていません。install-docker.sh を実行してください。"

main() {
    log_info "=== Immich セットアップ開始 ==="

    # 設定値検証 (config.sh で定義済みの想定)
    : "${TIME_ZONE:?config.sh で TIME_ZONE が未定義です}"
    : "${IMMICH_DIR_PATH:?config.sh で IMMICH_DIR_PATH が未定義です}"
    if [ -z "$IMMICH_UPLOAD_LOCATION" ]; then
        IMMICH_UPLOAD_LOCATION="${IMMICH_DIR_PATH}/library"
        log_info "UPLOAD_LOCATION 未設定のためデフォルト(${IMMICH_UPLOAD_LOCATION})を使用"
    fi

    log_info "設定ディレクトリ: $IMMICH_DIR_PATH"
    log_info "アップロードディレクトリ: $IMMICH_UPLOAD_LOCATION"
    [ -n "$IMMICH_EXTERNAL_LIBRARY_PATH" ] && log_info "外部ライブラリパス: $IMMICH_EXTERNAL_LIBRARY_PATH"

    # ディレクトリ作成
    ensure_dir_exists "$IMMICH_DIR_PATH"
    ensure_dir_exists "$IMMICH_UPLOAD_LOCATION"
    [ -n "$IMMICH_EXTERNAL_LIBRARY_PATH" ] && ensure_dir_exists "$IMMICH_EXTERNAL_LIBRARY_PATH"

    cd "$IMMICH_DIR_PATH" || log_error "ディレクトリ移動失敗: $IMMICH_DIR_PATH"

    # docker-compose.yml と .env の取得
    log_info "docker-compose.yml をダウンロード中..."
    wget -qO docker-compose.yml \
      https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml \
      || log_error "docker-compose.yml のダウンロードに失敗"

    log_info ".env をダウンロード中..."
    wget -qO .env \
      https://github.com/immich-app/immich/releases/latest/download/example.env \
      || log_error ".env のダウンロードに失敗"

    # .env 更新 (TZ, UPLOAD_LOCATION)
    log_info ".env を更新中..."
    if grep -qE '^\s*#?\s*TZ=' .env; then
        sed -i -E "s|^\s*#?\s*TZ=.*|TZ=${TIME_ZONE}|" .env
    else
        echo "TZ=${TIME_ZONE}" >> .env
    fi
    if grep -qE '^\s*#?\s*UPLOAD_LOCATION=' .env; then
        sed -i -E "s|^\s*#?\s*UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${IMMICH_UPLOAD_LOCATION}|" .env
    else
        echo "UPLOAD_LOCATION=${IMMICH_UPLOAD_LOCATION}" >> .env
    fi

    # 外部ライブラリマウント (オプション)
    if [ -n "$IMMICH_EXTERNAL_LIBRARY_PATH" ]; then
        log_info "docker-compose.yml に外部ライブラリマウントを追加中..."
        marker='- /etc/localtime:/etc/localtime:ro'
        mount_line="      - ${IMMICH_EXTERNAL_LIBRARY_PATH}:/usr/src/app/external-library:ro"
        if grep -qF -- "$marker" docker-compose.yml; then
            if ! grep -qF -- "$mount_line" docker-compose.yml; then
                sed -i "/${marker//\//\\/}/a\\${mount_line}" docker-compose.yml \
                  && log_info "マウントポイントを追加しました"
            else
                log_info "マウントポイントは既に存在します"
            fi
        else
            log_warn "挿入マーカー '$marker' が見つかりません。手動確認をお願いします"
        fi
    fi

    # Docker イメージ pull & コンテナ起動
    log_info "Docker イメージをプル中..."
    sudo docker compose pull    || log_error "イメージプルに失敗"
    log_info "コンテナを起動中..."
    sudo docker compose up -d   || log_error "コンテナ起動に失敗"

    log_success "=== Immich セットアップ完了 ==="
    log_info "Web UI: http://<サーバーIP>:2283"
}

main "$@"
