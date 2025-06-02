# 家庭用メディアサーバー管理

本リポジトリは、家庭用のメディアサーバーをLinux環境で構築・運用するためのスクリプトや設定ファイルを管理します。

## システム概要

Ubuntu Serverをベースとし、Docker上でImmichとJellyfinを実行して、スマートフォンで撮影したメディアを一元管理します。

### 主要コンポーネント

- **Immich** - 画像・短尺動画の管理・公開
- **Jellyfin** - 長尺動画の管理・公開  
- **rclone** - クラウドストレージ連携
- **Cloudflare Tunnel/Access** - 外部アクセス制御

### データフロー

```
スマートフォン → クラウドストレージ → rclone → Immich外部ライブラリ
                                              ↓
                                        バックアップストレージ
```

## ドキュメント構成

### 📋 設計・構成
- [システム設計](docs/design/system-architecture.md) - 全体構成とデータフロー
- [統一サーバー構成](docs/design/server-configuration.md) - 開発・本番統一構成

### 🛠️ セットアップ・運用
- [環境構築ガイド](docs/setup/environment-setup.md) - 開発・本番環境セットアップ
- [運用ガイド](docs/operations/README.md) - 日常運用・メンテナンス

### ⚙️ 設定・スクリプト
- [Docker設定](docker/) - Immich/Jellyfin用Docker Compose
- [rclone設定](config/rclone/) - クラウドストレージ連携設定
- [運用スクリプト](scripts/) - バックアップ・同期スクリプト

## クイックスタート

### 共通手順
```bash
# リポジトリクローン
git clone <repository-url> ManageMediaServer
cd ManageMediaServer

# 自動環境検出・セットアップ
./scripts/setup/auto-setup.sh
```

セットアップスクリプトが自動的に環境を判定し、適切なセットアップを実行：
- **WSL環境**: 開発環境として構築
- **Ubuntu Server**: 本番環境として構築

### 通知システム設定（推奨）

システムの状態やバックアップ結果をスマートフォンに通知：

```bash
# Discord Webhook通知設定
./scripts/setup/setup-notification.sh --setup

# 自動監視設定（管理者権限必要）
sudo ./scripts/setup/setup-monitoring.sh --setup
sudo ./scripts/setup/setup-monitoring.sh --enable

# 設定確認・テスト
./scripts/setup/setup-notification.sh --status
./scripts/setup/setup-monitoring.sh --test
```

詳細手順: [通知システム設定ガイド](docs/setup/notification-setup.md)

### 手動セットアップ（詳細制御が必要な場合）

#### 開発環境（WSL）
```bash
# Windows側でクローン後、WSLで実行
./scripts/setup/setup-dev.sh
```

#### 本番環境（Ubuntu Server）
```bash
# Ubuntu Serverで実行
./scripts/setup/setup-prod.sh
```

### セキュリティ設定テスト（推奨）

本番環境でのセキュリティ設定適用前に、WSL環境で事前テストを実行：

```bash
# WSL環境でセキュリティ設定をテスト
wsl -d Ubuntu-24.04
cd /mnt/d/ManageMediaServer
./scripts/setup/setup-prod.sh --test-mode --security-only

# 本番環境でセキュリティ設定を適用
./scripts/setup/setup-prod.sh --security-only
```

詳細手順: [WSL環境でのセキュリティテスト](docs/operations/security-testing-wsl.md)

## ライセンス

MIT License