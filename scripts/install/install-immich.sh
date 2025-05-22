#!/bin/bash
#
# ImmichをDockerで設定・起動するスクリプト
#

set -e

# 色の設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# スクリプトのディレクトリパス
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." &> /dev/null && pwd)"

# 設定ディレクトリ
CONFIG_DIR="${PROJECT_ROOT}/config/docker/immich"
DATA_DIR="/mnt/mediaserver"

# ログ関数
log() {
  local level=$1
  local message=$2
  local color=$NC
  
  case $level in
    "INFO") color=$NC ;;
    "SUCCESS") color=$GREEN ;;
    "WARN") color=$YELLOW ;;
    "ERROR") color=$RED ;;
  esac
  
  echo -e "[$(date '+%H:%M:%S')] ${color}${message}${NC}"
}

# エラーハンドリング
handle_error() {
  log "ERROR" "エラーが発生しました: $1"
  exit 1
}

trap 'handle_error "$BASH_COMMAND"' ERR

# Dockerの確認
if ! command -v docker &> /dev/null; then
  log "ERROR" "Dockerがインストールされていません"
  log "INFO" "先に install-docker.sh を実行してください"
  exit 1
fi

# Docker Composeの確認
if ! docker compose version &> /dev/null; then
  log "ERROR" "Docker Composeがインストールされていません"
  log "INFO" "sudo apt install -y docker-compose-plugin を実行してください"
  exit 1
fi

# 設定ディレクトリの作成
log "INFO" "設定ディレクトリを確認/作成しています..."
mkdir -p "${CONFIG_DIR}"

# データディレクトリの作成
log "INFO" "データディレクトリを確認/作成しています..."
if [ ! -d "${DATA_DIR}" ]; then
  log "WARN" "${DATA_DIR} が存在しません。作成しますか？ (y/N)"
  read -r response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    log "INFO" "${DATA_DIR} を作成しています..."
    mkdir -p "${DATA_DIR}/photos"
    mkdir -p "${DATA_DIR}/config/immich"
  else
    log "WARN" "データディレクトリの作成をスキップします。手動で作成してください。"
  fi
fi

# Docker Compose 設定ファイルの作成
COMPOSE_FILE="${CONFIG_DIR}/docker-compose.yml"
ENV_FILE="${CONFIG_DIR}/environment.yaml"

if [ ! -f "${COMPOSE_FILE}" ]; then
  log "INFO" "Docker Compose ファイルを作成しています..."
  cat > "${COMPOSE_FILE}" << 'EOF'
version: '3.8'

services:
  immich-server:
    container_name: immich-server
    image: ghcr.io/immich-app/immich-server:release
    command: [ "start.sh", "immich" ]
    volumes:
      - ${IMMICH_DATA_DIR}/photos:/usr/src/app/upload
      - ${IMMICH_CONFIG_DIR}:/usr/src/app/config
    env_file:
      - ./environment.yaml
    ports:
      - 2283:3001
    depends_on:
      - redis
      - database
    restart: always

  immich-microservices:
    container_name: immich-microservices
    image: ghcr.io/immich-app/immich-server:release
    command: [ "start.sh", "microservices" ]
    volumes:
      - ${IMMICH_DATA_DIR}/photos:/usr/src/app/upload
      - ${IMMICH_CONFIG_DIR}:/usr/src/app/config
    env_file:
      - ./environment.yaml
    depends_on:
      - redis
      - database
    restart: always

  immich-machine-learning:
    container_name: immich-machine-learning
    image: ghcr.io/immich-app/immich-machine-learning:release
    volumes:
      - ${IMMICH_DATA_DIR}/photos:/usr/src/app/upload
      - ${IMMICH_CONFIG_DIR}/machine-learning:/cache
    env_file:
      - ./environment.yaml
    restart: always

  redis:
    container_name: immich-redis
    image: redis:6.2-alpine
    restart: always

  database:
    container_name: immich-postgres
    image: postgres:14-alpine
    env_file:
      - ./environment.yaml
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_DB: ${DB_DATABASE_NAME}
    volumes:
      - ${IMMICH_CONFIG_DIR}/database:/var/lib/postgresql/data
    restart: always

volumes:
  immich-data:
  immich-config:
EOF
  log "SUCCESS" "Docker Compose ファイルを作成しました: ${COMPOSE_FILE}"
else
  log "INFO" "Docker Compose ファイルは既に存在します"
fi

# 環境変数ファイルの作成
if [ ! -f "${ENV_FILE}" ]; then
  log "INFO" "環境変数ファイルを作成しています..."
  
  # ランダムなパスワードを生成
  DB_PASSWORD=$(openssl rand -base64 12)
  
  cat > "${ENV_FILE}" << EOF
# 基本設定
NODE_ENV=production
LOG_LEVEL=warn

# データディレクトリ
IMMICH_DATA_DIR=${DATA_DIR}/photos
IMMICH_CONFIG_DIR=${DATA_DIR}/config/immich

# データベース設定
DB_HOSTNAME=database
DB_PORT=5432
DB_USERNAME=postgres
DB_PASSWORD=${DB_PASSWORD}
DB_DATABASE_NAME=immich

# Redis設定
REDIS_HOSTNAME=redis
REDIS_PORT=6379
REDIS_PASSWORD=

# 機械学習設定
MACHINE_LEARNING_CACHE_FOLDER=/cache
MACHINE_LEARNING_WORKERS=2

# Web設定
PUBLIC_IMMICH_SERVER_URL=http://immich-server:3001
PUBLIC_LOGIN_PAGE_MESSAGE=Welcome to Immich

# アップロード設定
UPLOAD_LOCATION=/usr/src/app/upload
EOF
  log "SUCCESS" "環境変数ファイルを作成しました: ${ENV_FILE}"
else
  log "INFO" "環境変数ファイルは既に存在します"
fi

# Docker Composeの起動
log "INFO" "Immichコンテナを起動しています..."
cd "${CONFIG_DIR}" || exit 1
docker compose up -d

# 状態確認
log "INFO" "コンテナの状態を確認しています..."
docker compose ps

log "SUCCESS" "Immichのセットアップが完了しました"
log "INFO" "ブラウザで http://localhost:2283 にアクセスして初期設定を行ってください"

exit 0
