# TODO（今後の課題詳細）

## 1. Linux移行計画

### 1.1 開発環境のセットアップ
- [x] WSL2のインストールと設定
  - [x] Windows機能の有効化（`dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart`）
  - [x] 仮想マシンプラットフォームの有効化（`dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart`）
  - [x] WSL2をデフォルトとして設定（`wsl --set-default-version 2`）
- [x] Ubuntu 22.04 LTS導入
  - [x] Microsoft Storeからインストール、または`wsl --install -d Ubuntu-22.04`
  - [x] 初期ユーザー設定、sudo権限確認
- [ ] Docker Desktop for Windows設定
  - [ ] WSL2バックエンド選択
  - [ ] Ubuntuディストリビューションとの統合設定
  - [ ] リソース割り当て（メモリ、CPU、ストレージ）最適化
- [ ] VS Codeセットアップ
  - [ ] Remote WSL拡張機能のインストール
  - [ ] Docker拡張機能設定
  - [ ] Git連携設定
- [ ] Gitリポジトリ構成
  - [ ] WSL内でのリポジトリクローン（`git clone https://github.com/username/ManageMediaServer.git`）
  - [ ] Git認証情報の設定（SSH鍵またはPATの生成と設定）

### 1.2 Linuxサーバー用コンテナ構成
- [ ] Immich構成
  ```yaml
  # docker-compose.immich.yml サンプル
  version: '3'
  services:
    immich-server:
      image: ghcr.io/immich-app/immich-server:release
      volumes:
        - /path/to/photos:/photos
        - immich-data:/data
  ```
- [ ] Jellyfin構成
  ```yaml
  # docker-compose.jellyfin.yml サンプル
  version: '3'
  services:
    jellyfin:
      image: jellyfin/jellyfin:latest
      volumes:
        - /path/to/media:/media
        - jellyfin-config:/config
  ```
- [ ] Cloudflare Tunnel設定
  - [ ] cloudflared導入（`curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb`）
  - [ ] トンネル作成と設定（`cloudflared tunnel create media-server`）
  - [ ] DNS CNAME設定
- [ ] rclone設定
  - [ ] rcloneインストール（`curl https://rclone.org/install.sh | sudo bash`）
  - [ ] リモートストレージ設定（`rclone config`）
  - [ ] 定期バックアップcronジョブ（`0 2 * * * rclone sync /path/to/data remote:backup --log-file=/var/log/rclone.log`）

### 1.3 ディレクトリ構造設計
- [ ] マウントポイント設計
  ```bash
  # ディレクトリ構造例
  /mnt/mediaserver/
  ├── photos/       # Immich用写真ライブラリ
  ├── videos/       # Jellyfin用動画ライブラリ
  ├── music/        # 音楽ファイル
  ├── backups/      # バックアップデータ
  └── config/       # アプリケーション設定
      ├── immich/
      ├── jellyfin/
      └── rclone/
  ```
- [ ] パーミッション設定
  - [ ] グループベースのアクセス制御（`sudo groupadd mediaserver`）
  - [ ] アプリケーション間の共有設定（`chmod 775 /mnt/mediaserver/photos`）
  - [ ] ACLによる詳細なパーミッション（`setfacl -m g:docker:rx /mnt/mediaserver/config`）
- [ ] バックアップスクリプト適応
  - [ ] Linux向けのrsync/rcloneスクリプト
  - [ ] 差分バックアップと完全バックアップの組み合わせ

### 1.4 デプロイスクリプト作成
- [ ] サーバー初期セットアップスクリプト
  ```bash
  #!/bin/bash
  # setup_server.sh
  
  # システムアップデート
  apt update && apt upgrade -y
  
  # 必要なツールのインストール
  apt install -y docker.io docker-compose git curl
  
  # ユーザーをdockerグループに追加
  usermod -aG docker $USER
  
  # ディレクトリ構造作成
  mkdir -p /mnt/mediaserver/{photos,videos,music,backups,config/{immich,jellyfin,rclone}}
  ```
- [ ] アプリケーションデプロイスクリプト
  - [ ] Docker Composeによる一括デプロイ
  - [ ] 設定ファイルの自動生成と配置
- [ ] 監視スクリプト
  ```bash
  #!/bin/bash
  # monitor.sh
  
  # サービス状態チェック
  docker ps --format "{{.Names}}: {{.Status}}" | grep -v "Up"
  
  # ディスク使用量チェック
  df -h /mnt/mediaserver | awk 'NR>1 {print $5 " used on " $6}'
  
  # 必要に応じて再起動
  docker-compose -f /path/to/docker-compose.yml restart
  ```

### 1.5 テスト計画
- [ ] ローカルWSL環境でのテスト
  - [ ] エンドツーエンドテスト手順
  - [ ] パフォーマンス検証方法
  - [ ] ネットワーク設定確認項目
- [ ] 本番環境への移行手順
  - [ ] 事前チェックリスト
  - [ ] データバックアップ確認
  - [ ] 切り替え手順と切り戻し手順
- [ ] データ移行戦略
  - [ ] 大容量データの効率的な移行方法（rsync、物理ディスク転送など）
  - [ ] メタデータとユーザー情報の移行手順
  - [ ] 移行後の整合性チェック方法

## 2. Immich・Jellyfin・rclone・Cloudflare Tunnel/Accessのセットアップ・自動化
- [ ] 各サービスのインストール手順の明文化
- [ ] PowerShellやバッチ等による自動化スクリプトの作成・整備
- [ ] サービスごとの設定ファイル例・テンプレートの用意
- [ ] WSLやDocker等の利用有無・構成パターンの整理

## 3. バックアップ運用・障害時リカバリ手順
- [ ] バックアップ対象・頻度・世代管理の方針策定
- [ ] バックアップ/リストア用スクリプトの作成
- [ ] 障害発生時の復旧手順（例：ストレージ障害、データ消失時の対応）

## 4. セキュリティ強化
- [ ] Cloudflare Accessの詳細設定例（ユーザー管理、認証方式、IP制限等）
- [ ] サーバー側のファイアウォール・アクセス制御のベストプラクティス
- [ ] ログ監視・不正アクセス検知の仕組み検討

## 5. 運用監視・ヘルスチェック・通知
- [ ] サービス稼働監視・死活監視スクリプトの作成
- [ ] Slack等への自動通知仕組みの整備
- [ ] 定期的なストレージ容量・エラー監視の自動化

## 6. テスト・運用マニュアル
- [ ] システム全体の動作検証手順・チェックリスト
- [ ] 新規セットアップ時の手順書
- [ ] 日常運用・トラブルシューティングマニュアル

---

※各項目は今後の進捗に応じて随時アップデート・詳細化していきます。
