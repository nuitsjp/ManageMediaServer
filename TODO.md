# 開発TODO

## フェーズ1: 基盤構築 🏗️

### 必須（高優先度）
- [x] **統合セットアップスクリプト作成** ✅
  - [x] `scripts/setup/auto-setup.sh` - 環境自動判定 ✅
  - [x] `scripts/setup/setup-dev.sh` - 開発環境セットアップ ✅
  - [x] `scripts/setup/setup-prod.sh` - 本番環境セットアップ ✅
  - [x] **環境変数設定の自動化** ⭐ 物理パス差分吸収の核心 ✅
    - [x] 環境検出ロジック（WSL vs Ubuntu Server） ✅
    - [x] 適切な環境変数ファイル生成（.env.local） ✅
    - [x] シェル環境への環境変数設定（.bashrc/.profile） ✅

- [x] **物理ディレクトリ差分吸収機構** ⭐ 新規追加 ✅
  - [x] `config/env/` ディレクトリ作成 ✅
  - [x] `config/env/dev.env` - 開発環境用パス設定テンプレート ✅
  - [x] `config/env/prod.env` - 本番環境用パス設定テンプレート ✅
  - [x] `scripts/lib/env-loader.sh` - 環境変数読み込みライブラリ ✅
  - [x] すべてのスクリプトでの環境変数利用統一 ✅

- [x] **Docker設定作成** ✅ **完了**
  - [x] `docker/dev/docker-compose.yml` - 開発環境用 ✅
  - [x] `docker/dev/.env.example` - 開発環境用環境変数テンプレート ✅
  - [x] `docker/prod/immich/docker-compose.yml` - 本番Immich用 ✅
  - [x] `docker/prod/jellyfin/docker-compose.yml` - 本番Jellyfin用 ✅

- [x] **基本設定ファイル** ✅ **完了**
  - [x] `config/rclone/rclone.conf.example` - rclone設定テンプレート ✅
  - [x] `config/systemd/rclone-sync.service` - systemdサービス設定 ✅ (setup-prod.shで自動生成)
  - [x] `config/systemd/rclone-sync.timer` - systemdタイマー設定 ✅ (setup-prod.shで自動生成)

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
- ✅ **フェーズ1: 基盤構築** (**100%完了!** 🎉)
  - ✅ 統合セットアップスクリプト完成
  - ✅ 環境変数システム完成  
  - ✅ 開発環境Docker設定完成
  - ✅ 本番環境Docker設定完成
  - ✅ 設定ファイルテンプレート完成
  - ⏳ **WSL実地テスト待ち** ⭐ フェーズ2開始準備完了

### 次のマイルストーン 
- 🔄 **フェーズ2: 開発環境検証** (準備完了・開始待ち)

### 完了済み
- ✅ システム設計・アーキテクチャ設計
- ✅ ドキュメント構造設計
- ✅ 統一構成方針決定
- ✅ **フェーズ1: 基盤構築 完全完了** 🎉
  - ✅ 統合セットアップスクリプト実装
    - ✅ 環境自動判定機能（WSL vs Ubuntu Server）
    - ✅ 環境変数システム（物理パス差分完全吸収）
    - ✅ 共通ライブラリ（common.sh, env-loader.sh, config.sh）
    - ✅ 開発環境セットアップ完全版
    - ✅ 本番環境セットアップ完全版
  - ✅ **Docker Compose設定完全版**
    - ✅ 開発環境設定（完全版 docker-compose.yml）
    - ✅ 本番Immich設定
    - ✅ 本番Jellyfin設定
    - ✅ 開発用便利スクリプト（start/stop/reset）
    - ✅ 改行コード自動変換機能
  - ✅ **設定ファイルテンプレート**
    - ✅ rclone設定テンプレート
    - ✅ systemd設定（スクリプト内で自動生成）

### 直近の優先タスク（今週）
1. [x] **不足ファイル作成** ✅ **完了**
   - [x] `docker/prod/immich/docker-compose.yml` 作成 ✅
   - [x] `docker/prod/jellyfin/docker-compose.yml` 作成 ✅
   - [x] `config/rclone/rclone.conf.example` テンプレート作成 ✅

2. [ ] **WSL開発環境での実地テスト** ⭐ **現在のメインタスク**
   - [ ] `./scripts/setup/auto-setup.sh` の実行テスト
   - [ ] Docker Composeでのサービス起動確認  
   - [ ] 改行コード問題の解決確認
   - [ ] 基本動作フロー確認

3. [ ] **フェーズ2移行** 
   - [ ] 実地テスト完了後にフェーズ2（開発環境検証）開始
   - [ ] 問題があれば修正してフェーズ1完了

### 注意事項・メモ
- 開発環境と本番環境の論理構成統一を最優先
- **物理パス差分は環境変数で完全吸収** ⭐ 重要方針（詳細は[SCRIPT_DESIGN.md](SCRIPT_DESIGN.md#物理パス差分吸収)参照）
- セットアップスクリプトは冪等性を保つ
- エラーハンドリングは後回しにせず、最初から組み込む
- 設定ファイルはテンプレート化し、機密情報は環境変数で管理
