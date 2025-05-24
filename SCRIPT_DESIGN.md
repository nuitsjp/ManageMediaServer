# スクリプト設計方針

## 基本方針

### エラーハンドリング
- **単純な停止方式**: エラー発生時は全体を中断し、再実行は先頭から行う
- **冪等性の担保**: 同じスクリプトを何度実行しても安全になるよう設計
- **ロールバック不要**: アンインストール用スクリプトを別途用意して対応
- **既存設定の上書き**: 既存の設定ファイルは確認なしで上書き（バックアップ付き）

### 対象環境
- **OS**: Ubuntu 24.04 LTS固定
- **ディストリビューション変更対応**: 変数による共通定義で将来的な変更に対応
- **WSL/Linuxサーバー差異**: 必要に応じて環境判定で分岐処理

### 設定管理
- **環境変数方式**: 物理パス差分を環境変数で完全吸収
- **機密情報**: 当面はデフォルト値を使用（Immich PostgreSQLパスワードなど）
- **設定ファイル**: config/env/配下で環境別管理

### UI/UX
- **プログレス表示**: 各処理ステップでログ出力、詳細はquietオプションで抑制
- **中断・再開機能**: 実装しない（冪等性により再実行で対応）
- **対話モード**: 実装しない（事前設定に依存）

## 統一論理構成

開発環境（WSL）と本番環境（Ubuntu Server）で同一の論理構成を使用します。

### 統一ディレクトリ構成

```
${PROJECT_ROOT}/            # プロジェクトルート
├── docs/                   # ドキュメント
├── docker/                 # Docker Compose設定
│   ├── dev/               # 開発環境用
│   └── prod/              # 本番環境用
├── config/                 # 設定ファイル・テンプレート
│   └── env/               # 環境別設定
│       ├── dev.env        # 開発環境用パス設定
│       ├── prod.env       # 本番環境用パス設定
│       └── common.env     # 共通設定
├── scripts/               # 運用スクリプト
│   ├── setup/             # セットアップスクリプト（共通）
│   ├── lib/               # 共通ライブラリ
│   │   ├── common.sh      # ログ、ユーティリティ
│   │   ├── config.sh      # 設定管理
│   │   └── env-loader.sh  # 環境変数読み込み
│   ├── install/           # インストールスクリプト
│   ├── uninstall/         # アンインストールスクリプト
│   ├── deploy/            # デプロイスクリプト
│   └── sync/              # 同期スクリプト
└── README.md

${DATA_ROOT}/               # データルート（環境変数で指定）
├── immich/                 # Immich外部ライブラリ
├── jellyfin/               # Jellyfinライブラリ
├── temp/                   # 一時作業領域
└── config/                 # 実行時設定
    └── rclone/

${BACKUP_ROOT}/             # バックアップルート（環境変数で指定）
├── media/                  # メディアバックアップ
├── config/                 # 設定バックアップ
└── system/                 # システムバックアップ
```

### 環境別パス設定

#### 開発環境（WSL）
```bash
# config/env/dev.env
PROJECT_ROOT="/mnt/d/ManageMediaServer"
DATA_ROOT="$HOME/dev-data"
BACKUP_ROOT="$HOME/dev-backup"
COMPOSE_FILE="docker/dev/docker-compose.yml"
```

#### 本番環境（Ubuntu Server）
```bash
# config/env/prod.env
PROJECT_ROOT="/home/mediaserver/ManageMediaServer"
DATA_ROOT="/mnt/data"
BACKUP_ROOT="/mnt/backup"
COMPOSE_FILE="docker/prod/immich/docker-compose.yml"
```

## アーキテクチャ

### スクリプト呼び出し方式
```bash
# インストール
./scripts/setup.sh                    # 全体セットアップ
./scripts/setup.sh docker immich      # カテゴリー別セットアップ

# アンインストール
./scripts/uninstall.sh               # 全体アンインストール
./scripts/uninstall.sh docker --force # 強制アンインストール
```

## 物理パス差分吸収 📁

### 実装方針: 環境変数 + 設定ファイル方式

**データフロー:**
```
config/env/dev.env → env-loader.sh → 環境変数展開 → 各スクリプトで利用
config/env/prod.env →              → シェル環境永続化
```

### 環境検出ロジック

```bash
# scripts/lib/env-loader.sh
detect_environment() {
    if grep -qE "(Microsoft|WSL)" /proc/version 2>/dev/null; then
        echo "dev"
    elif [ -f /etc/os-release ] && grep -q "Ubuntu" /etc/os-release; then
        echo "prod"
    else
        echo "unknown"
    fi
}

# 適切な設定ファイル読み込み
load_environment() {
    local env_type=$(detect_environment)
    local config_file="${PROJECT_ROOT:-$(dirname "$0")/../..}/config/env/${env_type}.env"
    
    if [ -f "$config_file" ]; then
        source "$config_file"
        export PROJECT_ROOT DATA_ROOT BACKUP_ROOT COMPOSE_FILE
    else
        log_error "設定ファイルが見つかりません: $config_file"
    fi
}
```

## 技術仕様

### 共通スクリプト構造
```bash
#!/bin/bash
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/env-loader.sh" || log_error "env-loader.sh の読み込みに失敗"

# 環境変数読み込み
load_environment

# メイン処理
main() {
    log_info "=== [サービス名] インストール開始 ==="
    
    # 事前チェック
    pre_check
    
    # 冪等性チェック
    if is_already_installed; then
        log_success "[サービス名]は既にインストール済みです"
        return 0
    fi
    
    # インストール処理（環境変数を利用）
    install_service
    
    log_success "=== [サービス名] インストール完了 ==="
}

main "$@"
```

### 共通ライブラリ機能 (common.sh)

#### ログ機能
```bash
log_info()    # 青色: 情報メッセージ
log_success() # 緑色: 成功メッセージ
log_warning() # 黄色: 警告メッセージ
log_error()   # 赤色: エラーメッセージ（exit 1を含む）
log_debug()   # 灰色: デバッグメッセージ（DEBUG=1時のみ）
```

#### ユーティリティ関数
```bash
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

wait_for_service() {
    local service_name=$1
    local timeout=${2:-30}
    # systemctl is-active でサービス状態を確認
}

ensure_dir_exists() {
    local dir=$1
    [ -d "$dir" ] || mkdir -p "$dir"
}
```

### 設定管理統合 (config.sh + env-loader.sh)

```bash
# scripts/lib/config.sh - アプリケーション固有設定
# システム設定
export OS_NAME="Ubuntu"
export OS_VERSION="24.04"
export TIME_ZONE="${TIME_ZONE:-Asia/Tokyo}"

# Immich設定（環境変数ベースパスを利用）
export IMMICH_DIR_PATH="${DATA_ROOT}/immich"
export IMMICH_DB_PASSWORD="${IMMICH_DB_PASSWORD:-postgres}"

# Jellyfin設定
export JELLYFIN_CONFIG_PATH="${DATA_ROOT}/jellyfin/config"
export JELLYFIN_MEDIA_PATH="${DATA_ROOT}/jellyfin/movies"

# Cloudflare設定
export CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
export CLOUDFLARE_TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-homelab-tunnel}"

# rclone設定
export RCLONE_CONFIG_PATH="${DATA_ROOT}/config/rclone/rclone.conf"
export RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-gdrive}"
```

### Docker Compose連携
```bash
# 自動生成される docker/dev/.env.local
PROJECT_ROOT=/mnt/d/ManageMediaServer
DATA_ROOT=/home/user/dev-data
BACKUP_ROOT=/home/user/dev-backup
```

```yaml
# docker/dev/docker-compose.yml
services:
  immich:
    volumes:
      - "${DATA_ROOT}/immich:/usr/src/app/upload"
```

## 冪等性の実装パターン

#### パターン1: コマンド存在確認
```bash
is_already_installed() {
    command_exists docker && command_exists docker-compose
}
```

#### パターン2: 設定ファイル存在確認
```bash
is_already_installed() {
    [ -f "${DATA_ROOT}/immich/docker-compose.yml" ]
}
```

#### パターン3: サービス稼働確認
```bash
is_already_installed() {
    systemctl is-active --quiet docker
}
```

## 実装優先順位

### Phase 1: 基盤整備
1. 環境変数システム（env-loader.sh, config/env/）
2. 共通ライブラリ（common.sh, config.sh）
3. メインスクリプト（setup.sh）

### Phase 2: アプリケーション
1. Docker インストールスクリプト
2. Immich セットアップ
3. Jellyfin セットアップ

### Phase 3: 外部連携
1. rclone セットアップ
2. Cloudflare Tunnel セットアップ
3. 同期スクリプト

### Phase 4: 運用支援
1. アンインストールスクリプト
2. デプロイスクリプト
3. 監視・ヘルスチェック

## コーディング規約

### 命名規則
- **関数名**: snake_case（例: `install_docker`, `load_environment`）
- **変数名**: 
  - グローバル/環境変数: UPPER_SNAKE_CASE（例: `DATA_ROOT`）
  - ローカル変数: snake_case（例: `local service_name`）
- **ファイル名**: kebab-case（例: `env-loader.sh`）

### コメント規則
```bash
# --- セクション区切り ---
# 関数の説明
# 引数: $1 - パラメータの説明
# 戻り値: 0 - 成功, 1 - 失敗
function_name() {
    # 処理内容の説明
}
```

### ログ出力規則
- **処理開始**: `log_info "処理名を開始中..."`
- **処理完了**: `log_success "処理名を完了しました"`
- **警告事項**: `log_warning "注意事項"`
- **エラー**: `log_error "エラー内容"` （自動的にexit 1）

## セキュリティ考慮事項

### 権限管理
- root権限が必要な処理は`pre_check()`で事前確認
- 一般ユーザーでの実行が推奨される場合は明示
- ファイル作成時は適切なパーミッション設定

### 機密情報の取り扱い
- パスワード等は環境変数で管理
- デフォルト値は安全でない旨を明記
- 将来的にはVaultやSecret管理ツールとの連携を検討

### 入力値検証
- ユーザー入力は最小限に抑える
- パス展開には注意（例: `"$var"` のようにクォート）
- 外部コマンドの実行結果は適切にエスケープ

## アンインストール方針

### 削除順序
依存関係を考慮した逆順での削除：
1. rclone（クラウド同期停止）
2. Cloudflare Tunnel（外部アクセス遮断）
3. Jellyfin（メディアサーバー停止）
4. Immich（写真管理停止）
5. Docker（最後にコンテナ基盤削除）

### データ保護
- **設定ファイル**: タイムスタンプ付きバックアップを作成
- **メディアデータ**: 削除前に確認プロンプト表示
- **データベース**: 削除対象から除外（手動削除を推奨）

### アンインストールスクリプト構造
```bash
# 削除前確認
if [ "$1" != "--force" ]; then
    confirm_action "本当に[サービス名]を削除しますか？"
fi

# サービス停止
stop_service

# 設定ファイル削除
remove_config_files

# データ削除（オプション）
if [ "$REMOVE_DATA" = "true" ]; then
    remove_data_files
fi
```

## 保守性向上のための指針

### ドキュメント
- 各スクリプトにヘッダーコメントで概要記載
- 複雑な処理には詳細なコメント追加
- 設定値の意味と影響を明記

### テスト容易性
- 関数は単一責任の原則に従う
- 環境依存部分は関数として分離
- デバッグモード（`DEBUG=1`）のサポート

### 拡張性
- 新サービス追加時はテンプレートをコピー
- 共通処理は積極的にライブラリ化
- 設定値は外部化して柔軟性確保

---

この設計方針は、プロジェクトの成長に応じて更新されます。
大きな方針変更がある場合は、このドキュメントを先に更新してから実装を進めてください。