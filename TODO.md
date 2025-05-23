# TODO（今後の課題詳細）

## 1. Linux移行計画

### 1.1 開発環境のセットアップ
- [x] WSL2のインストールと設定
  - [x] Windows機能の有効化（`dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart`）
  - [x] 仮想マシンプラットフォームの有効化（`dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart`）
  - [x] WSL2をデフォルトとして設定（`wsl --set-default-version 2`）
  - [x] Install-Wsl.ps1スクリプトの完成（自動化済み）
- [x] Ubuntu 24.04 LTS導入
  - [x] `wsl --install -d Ubuntu-24.04`による自動インストール
  - [x] 初期ユーザー設定、sudo権限確認
- [x] VS Codeセットアップ
  - [x] Remote WSL拡張機能のインストール（`code --install-extension ms-vscode-remote.remote-wsl`）
  - [x] Docker拡張機能設定（`code --install-extension ms-azuretools.vscode-docker`）
  - [x] Git連携設定
  - [x] WSL内でVS Codeを起動確認（`code .`）
  - [x] Setup-VSCode.ps1スクリプトの完成（自動化済み）
- [x] Gitリポジトリ構成
  - [x] Windows側の既存リポジトリを利用（WSLから /mnt/d/ManageMediaServer でアクセス）
  - [x] WSL内でのGit設定確認（Windows側の設定を継承）
  - [x] WSLからVS Codeでプロジェクト編集確認（`cd /mnt/d/ManageMediaServer && code .`）

### 1.2 Linuxサーバー用コンテナ構成 **← 次のステップ**
- [x] WSL環境でのDocker設定（Docker Desktop不使用）
  - [x] WSL内に直接Dockerをインストール（`sudo apt install docker.io docker-compose-plugin`）
  - [x] Dockerサービスの起動と自動起動設定（`sudo systemctl start docker && sudo systemctl enable docker`）
  - [x] ユーザーをDockerグループに追加（`sudo usermod -aG docker $USER`）
  - [x] インストールスクリプト作成（`scripts/install/install-docker.sh`）
- [ ] Immich構成
  - [ ] Docker Compose設定ファイルの作成（`config/docker/immich/docker-compose.yml`）
  - [ ] 環境変数ファイルの設定（`config/docker/immich/environment.yaml`）
  - [ ] インストールスクリプトの作成（`scripts/install/install-immich.sh`）
  - [ ] WSL環境でのテスト起動
- [ ] Jellyfin構成
  - [ ] Docker Compose設定ファイルの作成（`config/docker/jellyfin/docker-compose.yml`）
  - [ ] 環境変数ファイルの設定（`config/docker/jellyfin/environment.yaml`）
  - [ ] インストールスクリプトの作成（`scripts/install/install-jellyfin.sh`）
  - [ ] WSL環境でのテスト起動
- [ ] Cloudflare Tunnel設定
  - [ ] cloudflaredインストールスクリプト作成（`scripts/install/install-cloudflared.sh`）
  - [ ] トンネル作成と設定の自動化
  - [ ] 設定ファイルテンプレートの作成（`config/cloudflare/tunnel_config.yaml`）
- [ ] rclone設定
  - [ ] rcloneインストールスクリプト作成（`scripts/install/install-rclone.sh`）
  - [ ] 設定ファイルテンプレートの作成（`config/rclone/rclone.conf`）
  - [ ] 同期スクリプトの作成（`scripts/sync/sync-cloud-storage.sh`）

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
  apt install -y docker.io docker-compose-plugin git curl
  
  # ユーザーをdockerグループに追加
  usermod -aG docker $USER
  
  # ディレクトリ構造作成
  mkdir -p /mnt/mediaserver/{photos,videos,music,backups,config/{immich,jellyfin,rclone}}
  ```
- [ ] アプリケーションデプロイスクリプト
  - [ ] Docker Composeによる一括デプロイ（`scripts/deploy/deploy-all.sh`）
  - [ ] 設定ファイルの自動生成と配置（`scripts/deploy/generate-configs.sh`）
- [ ] 監視スクリプト
  ```bash
  #!/bin/bash
  # monitor.sh
  
  # サービス状態チェック
  docker ps --format "{{.Names}}: {{.Status}}" | grep -v "Up"
  
  # ディスク使用量チェック
  df -h /mnt/mediaserver | awk 'NR>1 {print $5 " used on " $6}'
  
  # 必要に応じて再起動
  docker compose -f /path/to/docker-compose.yml restart
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

### 1.6 スクリプト実装とアンインストール方針
- [ ] インストールスクリプトとアンインストールスクリプトの整合性確認
- [ ] 共通ライブラリ（common.sh, config.sh）適用状況の点検
- [ ] 既存設定ファイル上書きルールの適用確認
- [ ] 各サービスの削除順序とデータ保護手順の検討

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
