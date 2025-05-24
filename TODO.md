# 開発TODO

## フェーズ1: 基盤構築 🏗️

### 必須（高優先度）
- [ ] **統合セットアップスクリプト作成**
  - [ ] `scripts/setup/auto-setup.sh` - 環境自動判定
  - [ ] `scripts/setup/setup-dev.sh` - 開発環境セットアップ
  - [ ] `scripts/setup/setup-prod.sh` - 本番環境セットアップ
  - [ ] **環境変数設定の自動化** ⭐ 物理パス差分吸収の核心
    - [ ] 環境検出ロジック（WSL vs Ubuntu Server）
    - [ ] 適切な環境変数ファイル生成（.env.local）
    - [ ] シェル環境への環境変数設定（.bashrc/.profile）

- [ ] **物理ディレクトリ差分吸収機構** ⭐ 新規追加
  - [ ] `config/env/` ディレクトリ作成
  - [ ] `config/env/dev.env` - 開発環境用パス設定テンプレート
  - [ ] `config/env/prod.env` - 本番環境用パス設定テンプレート
  - [ ] `scripts/common/env-loader.sh` - 環境変数読み込みライブラリ
  - [ ] すべてのスクリプトでの環境変数利用統一

- [ ] **Docker設定作成**
  - [ ] `docker/dev/docker-compose.yml` - 開発環境用
  - [ ] `docker/dev/.env.example` - 開発環境用環境変数テンプレート
  - [ ] `docker/prod/immich/docker-compose.yml` - 本番Immich用
  - [ ] `docker/prod/jellyfin/docker-compose.yml` - 本番Jellyfin用

- [ ] **基本設定ファイル**
  - [ ] `config/rclone/rclone.conf.example` - rclone設定テンプレート
  - [ ] `config/systemd/rclone-sync.service` - systemdサービス設定
  - [ ] `config/systemd/rclone-sync.timer` - systemdタイマー設定

### 推奨（中優先度）
- [ ] **ドキュメント統合**
  - [ ] `docs/setup/environment-setup.md` - 統合セットアップガイド作成
  - [ ] **環境変数管理ガイド追加** - 物理パス設定方法の説明
  - [ ] 既存の`development-environment.md`の統合または削除判断

- [ ] **基本運用スクリプト**
  - [ ] `scripts/rclone/sync-photos.sh` - 画像同期スクリプト
  - [ ] `scripts/rclone/sync-videos.sh` - 動画同期スクリプト
  - [ ] `scripts/backup/backup-media.sh` - メディアバックアップスクリプト

## フェーズ2: 開発環境検証 🧪

### 必須
- [ ] **WSL開発環境での動作確認**
  - [ ] セットアップスクリプトの動作テスト
  - [ ] Docker Composeでのサービス起動確認
  - [ ] rclone設定・動作確認
  - [ ] VS Code Remote WSL連携確認

- [ ] **データフロー検証**
  - [ ] 模擬クラウドストレージ（ローカル）からの同期テスト
  - [ ] Immich外部ライブラリへの画像・動画保存確認
  - [ ] Jellyfinでの動画再生確認

### 推奨
- [ ] **開発用便利スクリプト**
  - [ ] `scripts/dev/start-services.sh` - 開発サービス一括起動
  - [ ] `scripts/dev/stop-services.sh` - 開発サービス一括停止
  - [ ] `scripts/dev/reset-dev-data.sh` - 開発データリセット

## フェーズ3: 本番環境対応 🚀

### 必須
- [ ] **本番環境セットアップ検証**
  - [ ] Ubuntu Server での自動セットアップテスト
  - [ ] ディスク構成・マウント設定の自動化
  - [ ] systemdサービス登録・起動確認

- [ ] **セキュリティ設定**
  - [ ] ファイアウォール設定の自動化
  - [ ] ユーザー権限設定の自動化
  - [ ] SSH設定の強化

### 推奨
- [ ] **運用自動化**
  - [ ] `scripts/prod/deploy.sh` - 本番デプロイスクリプト
  - [ ] `scripts/maintenance/update-system.sh` - システム更新スクリプト
  - [ ] `scripts/monitoring/health-check.sh` - ヘルスチェックスクリプト

## フェーズ4: 外部連携・高度機能 🌐

### 必須
- [ ] **Cloudflare連携**
  - [ ] Cloudflare Tunnel設定
  - [ ] Cloudflare Access設定
  - [ ] 外部アクセステスト

- [ ] **rclone実運用設定**
  - [ ] Google Photos連携設定
  - [ ] OneDrive連携設定
  - [ ] 定期同期の動作確認

### 推奨
- [ ] **監視・ログ**
  - [ ] ログローテーション設定
  - [ ] ディスク使用量監視
  - [ ] エラー通知機能

## フェーズ5: ドキュメント・保守性向上 📚

### 推奨
- [ ] **運用ドキュメント**
  - [ ] `docs/operations/README.md` - 運用ガイド
  - [ ] `docs/operations/backup-procedures.md` - バックアップ手順
  - [ ] `docs/operations/troubleshooting.md` - トラブルシューティング

- [ ] **保守性向上**
  - [ ] 設定ファイルのバリデーション機能
  - [ ] セットアップスクリプトのエラーハンドリング強化
  - [ ] ロールバック機能の実装

## 進捗管理

### 現在のフェーズ
- 🔄 **フェーズ1: 基盤構築** （進行中）

### 完了済み
- ✅ システム設計・アーキテクチャ設計
- ✅ ドキュメント構造設計
- ✅ 統一構成方針決定

### 直近の優先タスク（今週）
1. [ ] `scripts/setup/auto-setup.sh` 作成
2. [ ] `docker/dev/docker-compose.yml` 作成
3. [ ] WSL開発環境での動作確認

### 注意事項・メモ
- 開発環境と本番環境の論理構成統一を最優先
- **物理パス差分は環境変数で完全吸収** ⭐ 重要方針（詳細は[SCRIPT_DESIGN.md](SCRIPT_DESIGN.md#物理パス差分吸収)参照）
- セットアップスクリプトは冪等性を保つ
- エラーハンドリングは後回しにせず、最初から組み込む
- 設定ファイルはテンプレート化し、機密情報は環境変数で管理
