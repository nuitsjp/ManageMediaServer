# システムのセットアップ手順

このドキュメントでは、家庭用メディアサーバーの開発環境を構築するための具体的な手順を説明します。

## 1. リポジトリのクローン
プロジェクトのリポジトリをローカルにクローンします。以下のコマンドを実行してください。
```
git clone <リポジトリのURL>
```

## 2. Dockerのインストール
Dockerをインストールするために、次のスクリプトを実行します。
```
powershell -ExecutionPolicy Bypass -File scripts/install/install-docker.ps1
```

## 3. rcloneのインストール
rcloneをインストールするために、次のスクリプトを実行します。
```
powershell -ExecutionPolicy Bypass -File scripts/install/install-rclone.ps1
```

## 4. Cloudflareの設定
Cloudflareの設定を行うために、次のスクリプトを実行します。
```
powershell -ExecutionPolicy Bypass -File scripts/install/setup-cloudflare.ps1
```

## 5. Dockerコンテナの起動
ImmichとJellyfinのDockerコンテナを起動するために、以下のコマンドを実行します。
```
docker-compose -f config/docker/docker-compose.yml up -d
```

## 6. rcloneの設定
クラウドストレージの設定を行うために、`config/rclone/rclone.conf`を編集します。

## 7. バックアップスクリプトの実行
メディアファイルのバックアップを行うために、次のスクリプトを実行します。
```
powershell -ExecutionPolicy Bypass -File scripts/backup/backup-media.ps1
```

## 8. 同期スクリプトの実行
クラウドストレージと同期を行うために、次のスクリプトを実行します。
```
powershell -ExecutionPolicy Bypass -File scripts/sync/sync-cloud-storage.ps1
```

## 9. ドキュメントの確認
システムのセットアップと使用方法を確認するために、以下のドキュメントを参照してください。
- `docs/setup-guide.md`
- `docs/usage-guide.md`

## 10. ログの管理
`logs`ディレクトリを使用して、システムのログを管理します。