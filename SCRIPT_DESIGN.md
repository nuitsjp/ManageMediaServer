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
- **デフォルト値**: config.shに集約して管理
- **機密情報**: 当面はデフォルト値を使用（Immich PostgreSQLパスワードなど）
- **設定ファイル**: .envファイルでの管理、将来的なカスタマイズ対応を考慮

### UI/UX
- **プログレス表示**: 各処理ステップでログ出力、詳細はquietオプションで抑制
- **中断・再開機能**: 実装しない（冪等性により再実行で対応）
- **対話モード**: 実装しない（事前設定に依存）

## アーキテクチャ

### ディレクトリ構造
```
scripts/
├── setup.sh                 # メインエントリーポイント
├── uninstall.sh             # メインアンインストールスクリプト
├── lib/
│   ├── common.sh            # 共通ライブラリ（ログ、ユーティリティ）
│   └── config.sh            # 設定管理ライブラリ
├── install/
│   ├── install-docker.sh    # Docker インストール
│   ├── install-immich.sh    # Immich セットアップ
│   ├── install-jellyfin.sh  # Jellyfin セットアップ
│   ├── install-cloudflared.sh # Cloudflare Tunnel セットアップ
│   └── install-rclone.sh    # rclone セットアップ
├── uninstall/
│   ├── uninstall-docker.sh
│   ├── uninstall-immich.sh
│   ├── uninstall-jellyfin.sh
│   ├── uninstall-cloudflared.sh
│   └── uninstall-rclone.sh
├── deploy/
│   ├── deploy-all.sh        # 全サービス一括デプロイ
│   └── generate-configs.sh  # 設定ファイル自動生成
└── sync/
    └── sync-cloud-storage.sh # クラウドストレージ同期
```

### スクリプト呼び出し方式
```bash
# インストール
# 全体セットアップ
./setup.sh

# カテゴリー別セットアップ
./setup.sh docker
./setup.sh immich
./setup.sh jellyfin
./setup.sh cloudflare
./setup.sh rclone

# アンインストール
# 全体アンインストール（依存関係逆順）
./uninstall.sh

# カテゴリー別アンインストール
./uninstall.sh docker
./uninstall.sh immich
./uninstall.sh jellyfin
./uninstall.sh cloudflare
./uninstall.sh rclone

# 強制アンインストール（確認スキップ）
./uninstall.sh all --force
./uninstall.sh docker --force
```

## 技術仕様

### 共通スクリプト構造
全てのインストールスクリプトは以下の統一構造に従う：

```bash
#!/bin/bash
set -euo pipefail

# スクリプトディレクトリ取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 共通ライブラリ読み込み
source "$SCRIPT_DIR/../lib/common.sh" || { echo "[ERROR] common.sh の読み込みに失敗しました。" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/config.sh" || log_error "config.sh の読み込みに失敗しました。"

# 事前チェック関数
pre_check() {
    # 権限確認、依存関係チェック、設定値検証
}

# インストール済みチェック関数
is_already_installed() {
    # 冪等性のためのチェックロジック
    # 戻り値: 0=インストール済み, 1=未インストール
}

# メイン処理
main() {
    log_info "=== [サービス名] インストール開始 ==="
    
    # 事前チェック
    pre_check
    
    # 冪等性チェック
    if is_already_installed; then
        log_success "[サービス名]は既にインストール済みです"
        show_version_info  # オプション
        return 0
    fi
    
    # インストール処理
    install_service
    
    # 設定適用
    configure_service
    
    # 動作確認
    verify_installation
    
    log_success "=== [サービス名] インストール完了 ==="
}

# エントリーポイント
main "$@"
```

### 共通ライブラリ機能 (common.sh)

#### ログ機能
```bash
# ログレベル別出力関数
log_info()    # 青色: 情報メッセージ
log_success() # 緑色: 成功メッセージ
log_warning() # 黄色: 警告メッセージ
log_error()   # 赤色: エラーメッセージ（exit 1を含む）
log_debug()   # 灰色: デバッグメッセージ（DEBUG=1時のみ）
```

#### ユーティリティ関数
```bash
# コマンド存在確認
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# サービス起動待機
wait_for_service() {
    local service_name=$1
    local timeout=${2:-30}
    # systemctl is-active でサービス状態を確認
}

# ディレクトリ作成
ensure_dir_exists() {
    local dir=$1
    [ -d "$dir" ] || mkdir -p "$dir"
}

# 確認プロンプト（アンインストール時のみ使用）
confirm_action() {
    local message=$1
    # ユーザー確認を求める
}
```

### 設定管理 (config.sh)

```bash
# システム設定
export OS_NAME="Ubuntu"
export OS_VERSION="24.04"
export TIME_ZONE="${TIME_ZONE:-Asia/Tokyo}"

# パス設定
export BASE_DIR="${BASE_DIR:-/opt/services}"
export DATA_DIR="${DATA_DIR:-/var/lib/services}"

# Docker設定
export INSTALL_DOCKER_COMPOSE_STANDALONE="${INSTALL_DOCKER_COMPOSE_STANDALONE:-false}"

# Immich設定
export IMMICH_DIR_PATH="${IMMICH_DIR_PATH:-${BASE_DIR}/immich}"
export IMMICH_UPLOAD_LOCATION="${IMMICH_UPLOAD_LOCATION:-${DATA_DIR}/immich/library}"
export IMMICH_EXTERNAL_LIBRARY_PATH="${IMMICH_EXTERNAL_LIBRARY_PATH:-}"
export IMMICH_DB_PASSWORD="${IMMICH_DB_PASSWORD:-postgres}"

# Jellyfin設定
export JELLYFIN_CONFIG_PATH="${JELLYFIN_CONFIG_PATH:-${BASE_DIR}/jellyfin/config}"
export JELLYFIN_CACHE_PATH="${JELLYFIN_CACHE_PATH:-${BASE_DIR}/jellyfin/cache}"
export JELLYFIN_MEDIA_PATH="${JELLYFIN_MEDIA_PATH:-${DATA_DIR}/media}"

# Cloudflare設定
export CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
export CLOUDFLARE_TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-homelab-tunnel}"

# rclone設定
export RCLONE_CONFIG_PATH="${RCLONE_CONFIG_PATH:-${BASE_DIR}/rclone/rclone.conf}"
export RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-gdrive}"
```

### 冪等性の実装パターン

#### パターン1: コマンド存在確認
```bash
is_already_installed() {
    command_exists docker && command_exists docker-compose
}
```

#### パターン2: 設定ファイル存在確認
```bash
is_already_installed() {
    [ -f "${IMMICH_DIR_PATH}/docker-compose.yml" ] && \
    [ -f "${IMMICH_DIR_PATH}/.env" ]
}
```

#### パターン3: サービス稼働確認
```bash
is_already_installed() {
    systemctl is-active --quiet docker
}
```

#### パターン4: 複合条件確認
```bash
is_already_installed() {
    [ -f "${CONFIG_FILE}" ] && \
    docker ps --format '{{.Names}}' | grep -q "^${SERVICE_NAME}$"
}
```

### エラーハンドリング戦略

1. **即座に停止**: `set -euo pipefail` により、エラー時は即座に停止
2. **明確なエラーメッセージ**: `log_error` で原因を明示してから終了
3. **クリーンアップ不要**: 部分的な状態でも再実行で上書き可能
4. **依存関係チェック**: `pre_check()` で事前に依存関係を確認

### 環境判定と分岐処理

```bash
# WSL環境の判定
is_wsl() {
    grep -qE "(Microsoft|WSL)" /proc/version 2>/dev/null
}

# 環境別処理の例
if is_wsl; then
    # WSL固有の設定
    configure_wsl_specific_settings
else
    # 通常のLinuxサーバー設定
    configure_linux_server_settings
fi
```

## 実装優先順位

### Phase 1: 基盤整備
1. 共通ライブラリ（common.sh, config.sh）
2. メインスクリプト（setup.sh）
3. Docker インストールスクリプト

### Phase 2: アプリケーション
1. Immich セットアップ
2. Jellyfin セットアップ
3. 基本動作確認

### Phase 3: 外部連携
1. Cloudflare Tunnel セットアップ
2. rclone セットアップ
3. 同期スクリプト

### Phase 4: 運用支援
1. アンインストールスクリプト（個別・一括）
2. デプロイスクリプト
3. 監視・ヘルスチェック（将来実装）

## コーディング規約

### 命名規則
- **関数名**: snake_case（例: `install_docker`, `wait_for_service`）
- **変数名**: 
  - グローバル/環境変数: UPPER_SNAKE_CASE（例: `IMMICH_DIR_PATH`）
  - ローカル変数: snake_case（例: `local service_name`）
- **ファイル名**: kebab-case（例: `install-docker.sh`）

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