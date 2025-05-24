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

## ライセンス

MIT License