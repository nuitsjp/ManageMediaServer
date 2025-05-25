# 運用ガイド

このドキュメントでは、家庭用メディアサーバーの日常運用手順について説明します。

## 目次

1. [基本操作](#基本操作)
2. [サービス管理](#サービス管理)
3. [システム監視](#システム監視)
4. [バックアップ運用](#バックアップ運用)
5. [メンテナンス](#メンテナンス)
6. [トラブルシューティング](#トラブルシューティング)
7. [セキュリティ管理](#セキュリティ管理)

## 基本操作

### サービス接続

| サービス | URL | 用途 |
|---------|-----|------|
| Immich | http://localhost:2283 | 写真・動画管理 |
| Jellyfin | http://localhost:8096 | メディアストリーミング |

### 基本ディレクトリ構成

```
/home/mediaserver/ManageMediaServer/  # PROJECT_ROOT
├── docker/                          # Docker設定
├── scripts/                         # 運用スクリプト
└── docs/                           # ドキュメント

/mnt/data/                          # DATA_ROOT
├── immich/                         # Immichデータ
├── jellyfin/                       # Jellyfinデータ
└── temp/                          # 一時ファイル

/mnt/backup/                        # BACKUP_ROOT
├── media/                          # メディアバックアップ
├── config/                         # 設定バックアップ
└── deploy_backup_*/               # デプロイバックアップ
```

## サービス管理

### サービス操作

```bash
# サービス状態確認
sudo systemctl status immich
sudo systemctl status jellyfin

# サービス開始
sudo systemctl start immich
sudo systemctl start jellyfin

# サービス停止
sudo systemctl stop immich
sudo systemctl stop jellyfin

# サービス再起動
sudo systemctl restart immich
sudo systemctl restart jellyfin

# 自動起動設定確認
sudo systemctl is-enabled immich
sudo systemctl is-enabled jellyfin
```

### Docker コンテナ管理

```bash
# コンテナ状態確認
docker ps

# 特定サービスのログ確認
docker compose -f docker/immich/docker-compose.yml logs -f
docker compose -f docker/jellyfin/docker-compose.yml logs -f

# コンテナリソース使用量確認
docker stats

# イメージ更新
docker compose -f docker/immich/docker-compose.yml pull
docker compose -f docker/jellyfin/docker-compose.yml pull
```

## システム監視

### ヘルスチェック

```bash
# 基本ヘルスチェック
./scripts/monitoring/health-check.sh

# 詳細ヘルスチェック
./scripts/monitoring/health-check.sh --detailed

# JSON形式出力（モニタリングツール連携用）
./scripts/monitoring/health-check.sh --json

# 問題自動修復付きチェック
./scripts/monitoring/health-check.sh --fix-issues
```

### システムリソース監視

```bash
# CPU・メモリ使用量
htop

# ディスク使用量
df -h

# I/O統計
iostat -x 1

# ネットワーク接続
ss -tuln
```

### アプリケーション監視

```bash
# Immich API確認
curl http://localhost:2283/api/server-info/ping

# Jellyfin 確認
curl http://localhost:8096/health

# データベース接続確認（Immich）
docker exec immich_postgres psql -U postgres -d immich -c "SELECT version();"
```

## バックアップ運用

### デプロイ前バックアップ

```bash
# バックアップ付きデプロイ
./scripts/prod/deploy.sh --backup

# バックアップ確認
ls -la /mnt/backup/deploy_backup_*/
```

### 手動バックアップ

```bash
# 設定ファイルバックアップ
backup_date=$(date '+%Y%m%d_%H%M%S')
backup_dir="/mnt/backup/manual_backup_$backup_date"
mkdir -p "$backup_dir"
cp -r docker config "$backup_dir/"

# データベースバックアップ
docker exec immich_postgres pg_dump -U postgres immich > "$backup_dir/immich_db.sql"
```

### バックアップ復元

```bash
# 最新バックアップから復元
./scripts/prod/deploy.sh --rollback

# 特定バックアップから復元（手動）
backup_dir="/mnt/backup/deploy_backup_YYYYMMDD_HHMMSS"
sudo systemctl stop immich jellyfin
cp -r "$backup_dir/docker" ./
cp -r "$backup_dir/config" ./
sudo systemctl start immich jellyfin
```

## メンテナンス

### 定期メンテナンス（月次）

```bash
# システム更新
./scripts/maintenance/update-system.sh

# Docker クリーンアップ
docker system prune -f
docker volume prune -f

# ログローテーション確認
sudo logrotate -f /etc/logrotate.conf

# ディスク使用量確認
du -sh /mnt/data/* /mnt/backup/*
```

### セキュリティ更新（週次）

```bash
# セキュリティ更新のみ適用
./scripts/maintenance/update-system.sh --security-only

# システム再起動（必要に応じて）
./scripts/maintenance/update-system.sh --security-only --with-restart
```

### Docker更新（随時）

```bash
# Docker イメージ更新のみ
./scripts/maintenance/update-system.sh --docker-only

# 更新確認（ドライラン）
./scripts/maintenance/update-system.sh --dry-run
```

## トラブルシューティング

### 一般的な問題

#### サービスが起動しない

```bash
# サービス状態詳細確認
sudo systemctl status immich -l
sudo systemctl status jellyfin -l

# ログ確認
journalctl -u immich -f
journalctl -u jellyfin -f

# Dockerログ確認
docker compose -f docker/immich/docker-compose.yml logs
docker compose -f docker/jellyfin/docker-compose.yml logs
```

#### ディスク容量不足

```bash
# 容量確認
df -h

# 大きなファイル特定
du -h /mnt/data | sort -h | tail -20

# Docker使用量確認
docker system df

# 不要ファイル削除
./scripts/monitoring/health-check.sh --fix-issues
```

#### ネットワーク接続問題

```bash
# ネットワーク接続確認
ping 8.8.8.8

# DNS確認
nslookup google.com

# ファイアウォール確認
sudo ufw status verbose

# ポート確認
ss -tuln | grep -E ':(2283|8096)'
```

### 復旧手順

#### 緊急時復旧

1. **サービス停止**
   ```bash
   sudo systemctl stop immich jellyfin
   ```

2. **問題特定**
   ```bash
   ./scripts/monitoring/health-check.sh --detailed
   ```

3. **ロールバック実行**
   ```bash
   ./scripts/prod/deploy.sh --rollback
   ```

#### データ破損時の復旧

1. **バックアップ確認**
   ```bash
   ls -la /mnt/backup/
   ```

2. **設定復元**
   ```bash
   backup_dir="/mnt/backup/deploy_backup_LATEST"
   cp -r "$backup_dir/docker" ./
   cp -r "$backup_dir/config" ./
   ```

3. **データベース復元**
   ```bash
   cat "$backup_dir/immich_db.sql" | docker exec -i immich_postgres psql -U postgres immich
   ```

## セキュリティ管理

### セキュリティチェック

```bash
# UFWファイアウォール状態
sudo ufw status verbose

# fail2ban状態
sudo systemctl status fail2ban
sudo fail2ban-client status

# SSH設定確認
sudo sshd -T | grep -E "(PermitRootLogin|PasswordAuthentication|Port)"

# システム更新状況
apt list --upgradable
```

### ログ監視

```bash
# セキュリティログ確認
sudo journalctl -u ssh -since "1 day ago"
sudo tail -f /var/log/auth.log

# fail2ban ログ
sudo journalctl -u fail2ban -since "1 day ago"

# システムエラー
sudo journalctl --priority=err --since "1 day ago"
```

### アクセス制御

```bash
# SSH接続履歴
last -10

# アクティブユーザー
who

# ネットワーク接続確認
ss -tuln
netstat -tuln
```

## 定期作業チェックリスト

### 日次
- [ ] ヘルスチェック実行
- [ ] サービス状態確認
- [ ] ディスク使用量確認

### 週次
- [ ] セキュリティ更新適用
- [ ] ログ確認
- [ ] バックアップ状態確認

### 月次
- [ ] システム全体更新
- [ ] Dockerクリーンアップ
- [ ] 設定ファイルバックアップ
- [ ] セキュリティ監査

### 緊急時
- [ ] 問題特定（ヘルスチェック）
- [ ] ログ確認
- [ ] 必要に応じてロールバック
- [ ] 原因調査と恒久対策

## 問い合わせ・サポート

運用中に問題が発生した場合は、以下の情報を収集してから対応してください：

1. **システム情報**
   ```bash
   uname -a
   docker --version
   ./scripts/monitoring/health-check.sh --json
   ```

2. **ログ情報**
   ```bash
   sudo journalctl -u immich -since "1 hour ago"
   sudo journalctl -u jellyfin -since "1 hour ago"
   ```

3. **リソース情報**
   ```bash
   df -h
   free -h
   docker ps
   ```

詳細なトラブルシューティングについては [troubleshooting.md](troubleshooting.md) を参照してください。
