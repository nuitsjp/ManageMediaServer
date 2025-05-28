# トラブルシューティング

本番環境で発生する可能性のある問題とその解決方法について説明します。

## 目次

1. [一般的な診断手順](#一般的な診断手順)
2. [サービス関連の問題](#サービス関連の問題)
3. [パフォーマンス問題](#パフォーマンス問題)
4. [ストレージ関連の問題](#ストレージ関連の問題)
5. [ネットワーク関連の問題](#ネットワーク関連の問題)
6. [Docker関連の問題](#docker関連の問題)
7. [データベース関連の問題](#データベース関連の問題)
8. [セキュリティ関連の問題](#セキュリティ関連の問題)
9. [緊急時対応](#緊急時対応)

## 一般的な診断手順

### 基本情報収集

```bash
# システム基本情報
uname -a
cat /etc/os-release
df -h
free -h
uptime

# サービス状態確認
sudo systemctl status immich jellyfin docker
docker ps -a

# ヘルスチェック実行
./scripts/monitoring/health-check.sh --detailed
```

### ログ確認手順

```bash
# システムログ（最新100行）
sudo journalctl -n 100

# 特定サービスのログ
sudo journalctl -u immich -f
sudo journalctl -u jellyfin -f
sudo journalctl -u docker -f

# Dockerコンテナログ
docker logs immich_server
docker logs immich_postgres
docker logs jellyfin

# エラーログのみ抽出
sudo journalctl --priority=err --since "1 hour ago"
```

### 問題の分類

| 症状 | 可能性の高い原因 | 確認コマンド |
|------|------------------|--------------|
| サービス起動しない | 設定エラー、依存関係 | `systemctl status` |
| 応答が遅い | リソース不足、ネットワーク | `htop`, `iotop` |
| 接続できない | ファイアウォール、ポート | `ss -tuln`, `ufw status` |
| データが見えない | マウント、権限問題 | `mount`, `ls -la` |

## サービス関連の問題

### Immichサービスが起動しない

#### 症状
- `systemctl status immich` で failed状態
- Web UI（localhost:2283）にアクセスできない

#### 診断手順

```bash
# 1. サービス状態詳細確認
sudo systemctl status immich -l

# 2. サービスログ確認
sudo journalctl -u immich --since "10 minutes ago"

# 3. Docker Compose設定確認
cd /home/mediaserver/ManageMediaServer
docker-compose -f docker/immich/docker-compose.yml config

# 4. コンテナ状態確認
docker ps -a | grep immich
```

#### 解決方法

**設定エラーの場合:**
```bash
# 設定ファイル検証
docker-compose -f docker/immich/docker-compose.yml config

# 環境変数確認
cat docker/immich/.env

# 設定修正後、再起動
sudo systemctl restart immich
```

**依存関係の問題:**
```bash
# Dockerサービス確認
sudo systemctl status docker

# PostgreSQLコンテナ確認
docker ps | grep postgres

# 手動でコンテナ起動
docker-compose -f docker/immich/docker-compose.yml up -d
```

**権限問題:**
```bash
# ディレクトリ権限確認
ls -la /mnt/data/immich/

# 権限修正
sudo chown -R $USER:$USER /mnt/data/immich/
```

### Jellyfinサービスが起動しない

#### 診断手順

```bash
# サービス状態確認
sudo systemctl status jellyfin -l
sudo journalctl -u jellyfin --since "10 minutes ago"

# Docker設定確認
docker-compose -f docker/jellyfin/docker-compose.yml config

# ポート使用状況確認
sudo ss -tuln | grep 8096
```

#### 解決方法

**ポート競合:**
```bash
# ポート使用プロセス確認
sudo lsof -i :8096

# 必要に応じてプロセス終了
sudo kill -9 <PID>

# サービス再起動
sudo systemctl restart jellyfin
```

**設定ファイル問題:**
```bash
# 設定ディレクトリ確認
ls -la /mnt/data/jellyfin/config/

# 設定リセット（最終手段）
sudo systemctl stop jellyfin
rm -rf /mnt/data/jellyfin/config/*
sudo systemctl start jellyfin
```

## パフォーマンス問題

### 動作が重い・応答が遅い

#### 診断手順

```bash
# CPU/メモリ使用率確認
htop

# ディスクI/O確認
iotop -a

# ネットワーク使用量確認
iftop

# Docker リソース使用量
docker stats

# システム負荷確認
uptime
vmstat 1 5
```

#### 解決方法

**CPU使用率が高い場合:**
```bash
# 高CPU使用プロセス特定
top -o %CPU

# Dockerコンテナリソース制限
# docker-compose.ymlに以下を追加:
# deploy:
#   resources:
#     limits:
#       cpus: '2.0'
#       memory: 4G
```

**メモリ不足の場合:**
```bash
# メモリ使用量詳細
free -h
cat /proc/meminfo

# スワップ使用状況
swapon -s

# メモリリーク確認
ps aux --sort=-%mem | head -10

# 不要プロセス終了
sudo systemctl stop <不要なサービス>
```

**ディスクI/O問題:**
```bash
# ディスク使用量確認
df -h
du -sh /mnt/data/* | sort -h

# ディスクI/O待機プロセス確認
iotop -o

# ディスクエラー確認
sudo dmesg | grep -i "error\|fail"
```

### データベースが遅い

#### 診断手順

```bash
# PostgreSQL プロセス確認
docker exec immich_postgres ps aux

# データベース接続数確認
docker exec immich_postgres psql -U postgres -d immich -c "SELECT count(*) FROM pg_stat_activity;"

# データベースサイズ確認
docker exec immich_postgres psql -U postgres -d immich -c "SELECT pg_size_pretty(pg_database_size('immich'));"

# ロック状況確認
docker exec immich_postgres psql -U postgres -d immich -c "SELECT * FROM pg_locks WHERE NOT granted;"
```

#### 解決方法

```bash
# データベース統計更新
docker exec immich_postgres psql -U postgres -d immich -c "VACUUM ANALYZE;"

# インデックス確認・再構築
docker exec immich_postgres psql -U postgres -d immich -c "REINDEX DATABASE immich;"

# 接続プール調整（PostgreSQL設定）
docker exec immich_postgres psql -U postgres -c "SHOW max_connections;"

# 必要に応じてデータベース再起動
docker restart immich_postgres
```

## ストレージ関連の問題

### ディスク容量不足

#### 診断手順

```bash
# ディスク使用量確認
df -h

# 大きなファイル・ディレクトリ特定
du -sh /mnt/data/* | sort -h
du -sh /mnt/backup/* | sort -h

# Docker使用量確認
docker system df

# ログファイルサイズ確認
sudo du -sh /var/log/*
sudo journalctl --disk-usage
```

#### 解決方法

**一般的なクリーンアップ:**
```bash
# Docker クリーンアップ
docker system prune -f
docker volume prune -f
docker image prune -a -f

# ログクリーンアップ
sudo journalctl --vacuum-time=7d
sudo journalctl --vacuum-size=100M

# 一時ファイル削除
find /mnt/data/temp -type f -mtime +7 -delete 2>/dev/null || true
```

**バックアップクリーンアップ:**
```bash
# 古いバックアップ削除スクリプト実行
./scripts/backup/cleanup-backups.sh

# 手動で古いバックアップ削除
find /mnt/backup -type d -name "deploy_backup_*" -mtime +30 -exec rm -rf {} \;
```

### マウントポイントの問題

#### 症状
- `/mnt/data` や `/mnt/backup` にアクセスできない
- "Transport endpoint is not connected" エラー

#### 診断手順

```bash
# マウント状態確認
mount | grep /mnt
df -h | grep /mnt

# ファイルシステムエラー確認
sudo dmesg | grep -i "error\|fail" | grep -i "mnt"

# ディスク状態確認
sudo lsblk
sudo fdisk -l
```

#### 解決方法

```bash
# アンマウントして再マウント
sudo umount /mnt/data
sudo umount /mnt/backup
sudo mount -a

# ファイルシステムチェック（データ損失の可能性あり）
sudo fsck /dev/sdb1
sudo fsck /dev/sdc1

# /etc/fstab 確認・修正
sudo nano /etc/fstab
```

## ネットワーク関連の問題

### 外部からアクセスできない

#### 診断手順

```bash
# ポート開放状況確認
sudo ss -tuln | grep -E ':(2283|8096)'

# ファイアウォール状態確認
sudo ufw status verbose

# ネットワーク接続確認
ping 8.8.8.8
nslookup google.com

# ローカル接続確認
curl http://localhost:2283/api/server-info/ping
curl http://localhost:8096/health
```

#### 解決方法

**ファイアウォール設定:**
```bash
# ポート開放
sudo ufw allow from 192.168.0.0/16 to any port 2283
sudo ufw allow from 192.168.0.0/16 to any port 8096

# UFW状態確認
sudo ufw status numbered
```

**Docker ネットワーク問題:**
```bash
# Dockerネットワーク確認
docker network ls
docker network inspect bridge

# コンテナネットワーク確認
docker inspect immich_server | grep -A 5 "NetworkMode"

# ポートマッピング確認
docker port immich_server
docker port jellyfin
```

### DNS解決の問題

#### 診断手順

```bash
# DNS設定確認
cat /etc/resolv.conf

# DNS解決テスト
nslookup google.com
dig google.com

# ネットワーク設定確認
ip route
ip addr show
```

#### 解決方法

```bash
# DNS設定修正
sudo nano /etc/resolv.conf
# 以下を追加:
# nameserver 8.8.8.8
# nameserver 8.8.4.4

# ネットワーク再起動
sudo systemctl restart systemd-resolved
```

## Docker関連の問題

### Dockerデーモンが起動しない

#### 診断手順

```bash
# Docker サービス状態
sudo systemctl status docker -l

# Docker設定確認
sudo dockerd --debug --log-level=debug

# ディスク容量確認
df -h /var/lib/docker
```

#### 解決方法

```bash
# Docker データディレクトリ確認
sudo ls -la /var/lib/docker/

# Docker設定ファイル確認
sudo nano /etc/docker/daemon.json

# Dockerサービス再起動
sudo systemctl restart docker

# 必要に応じてDocker再インストール
sudo apt remove docker.io docker-compose
sudo apt install docker.io docker-compose
```

### コンテナが頻繁に再起動する

#### 診断手順

```bash
# コンテナ状態確認
docker ps -a

# コンテナログ確認
docker logs immich_server --tail 100
docker logs immich_postgres --tail 100

# リソース制限確認
docker stats --no-stream
```

#### 解決方法

```bash
# メモリ制限調整（docker-compose.yml）
deploy:
  resources:
    limits:
      memory: 4G
    reservations:
      memory: 2G

# ヘルスチェック設定確認
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:3001/api/server-info/ping"]
  interval: 30s
  timeout: 10s
  retries: 3
```

## データベース関連の問題

### PostgreSQL接続エラー

#### 症状
- "Connection refused" エラー
- "FATAL: database does not exist" エラー

#### 診断手順

```bash
# PostgreSQLコンテナ状態確認
docker ps | grep postgres
docker logs immich_postgres

# データベース接続テスト
docker exec immich_postgres psql -U postgres -l

# データベース存在確認
docker exec immich_postgres psql -U postgres -c "SELECT datname FROM pg_database;"
```

#### 解決方法

**データベース初期化:**
```bash
# PostgreSQLコンテナ停止
docker stop immich_postgres

# データベースデータリセット（注意：データ消失）
rm -rf /mnt/data/immich/postgres

# コンテナ再起動
docker-compose -f docker/immich/docker-compose.yml up -d immich_postgres

# データベース復元（バックアップがある場合）
cat /mnt/backup/immich_db_backup_latest.sql | docker exec -i immich_postgres psql -U postgres immich
```

### データベース破損

#### 診断手順

```bash
# データベース整合性チェック
docker exec immich_postgres psql -U postgres immich -c "SELECT * FROM pg_stat_database WHERE datname='immich';"

# テーブル確認
docker exec immich_postgres psql -U postgres immich -c "\dt"

# エラーログ確認
docker logs immich_postgres | grep -i "error\|fatal\|corrupt"
```

#### 解決方法

```bash
# データベース修復試行
docker exec immich_postgres psql -U postgres immich -c "VACUUM FULL;"
docker exec immich_postgres psql -U postgres immich -c "REINDEX DATABASE immich;"

# バックアップからの復元
backup_file="/mnt/backup/immich_db_backup_YYYYMMDD.sql"
if [ -f "$backup_file" ]; then
    docker exec immich_postgres psql -U postgres -c "DROP DATABASE IF EXISTS immich;"
    docker exec immich_postgres psql -U postgres -c "CREATE DATABASE immich;"
    cat "$backup_file" | docker exec -i immich_postgres psql -U postgres immich
fi
```

## セキュリティ関連の問題

### 不正アクセスの検出

#### 診断手順

```bash
# SSH接続ログ確認
sudo tail -100 /var/log/auth.log
sudo journalctl -u ssh --since "1 day ago"

# fail2ban状態確認
sudo fail2ban-client status
sudo fail2ban-client status sshd

# ネットワーク接続確認
sudo ss -tuln
sudo netstat -tuln
```

#### 解決方法

```bash
# 不正IPをブロック
sudo ufw deny from <不正IP>

# fail2ban設定強化
sudo nano /etc/fail2ban/jail.local
# bantime = 3600    # 1時間ブロック
# maxretry = 3      # 3回失敗でブロック

# SSH設定強化
sudo nano /etc/ssh/sshd_config
# PermitRootLogin no
# PasswordAuthentication no  # 鍵認証のみ
# MaxAuthTries 3

sudo systemctl restart ssh
```

### ファイアウォール問題

#### 診断手順

```bash
# UFW状態確認
sudo ufw status verbose

# iptables直接確認
sudo iptables -L -n

# ポート開放状況
sudo ss -tuln | grep LISTEN
```

#### 解決方法

```bash
# UFW リセット（注意：全ルール削除）
sudo ufw --force reset

# 基本設定再構築
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow from 192.168.0.0/16 to any port 2283
sudo ufw allow from 192.168.0.0/16 to any port 8096
sudo ufw enable
```

## 緊急時対応

### システム全体が応答しない

#### 緊急診断手順

```bash
# システム基本確認（SSHアクセス可能な場合）
uptime
free -h
df -h
ps aux | head -20

# 高負荷プロセス特定
top -o %CPU
top -o %MEM

# ディスク I/O 確認
iotop -a
```

#### 緊急対応手順

1. **高負荷プロセス停止**
   ```bash
   # Dockerサービス停止
   sudo systemctl stop immich jellyfin
   
   # 必要に応じて強制終了
   sudo pkill -f immich
   sudo pkill -f jellyfin
   ```

2. **リソース確保**
   ```bash
   # メモリクリア
   sudo sync && sudo sysctl vm.drop_caches=3
   
   # 不要プロセス終了
   sudo systemctl stop <不要サービス>
   ```

3. **段階的復旧**
   ```bash
   # Docker サービス再起動
   sudo systemctl restart docker
   
   # サービス個別起動
   sudo systemctl start immich
   sleep 30
   sudo systemctl start jellyfin
   ```

### データ破損・完全復旧

#### 緊急バックアップ

```bash
# 現在の状態をバックアップ
emergency_backup="/mnt/backup/emergency_$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$emergency_backup"

# 重要設定保存
cp -r docker config "$emergency_backup/" 2>/dev/null || true

# データベース緊急バックアップ（可能な場合）
docker exec immich_postgres pg_dump -U postgres immich > "$emergency_backup/immich_emergency.sql" 2>/dev/null || true
```

#### 完全復旧手順

1. **サービス停止**
   ```bash
   sudo systemctl stop immich jellyfin
   docker stop $(docker ps -q) || true
   ```

2. **最新バックアップから復元**
   ```bash
   ./scripts/prod/deploy.sh --rollback
   ```

3. **段階的起動・確認**
   ```bash
   # データベース起動確認
   docker-compose -f docker/immich/docker-compose.yml up -d immich_postgres
   sleep 30
   
   # アプリケーション起動
   sudo systemctl start immich jellyfin
   
   # 動作確認
   ./scripts/monitoring/health-check.sh
   ```

### エスカレーション判断基準

| 状況 | 対応レベル | 目標復旧時間 |
|------|------------|--------------|
| 単一サービス停止 | Level 1 | 15分 |
| 複数サービス停止 | Level 2 | 30分 |
| システム応答なし | Level 3 | 1時間 |
| データ破損疑い | Level 4 | 4時間 |

### 復旧後チェックリスト

- [ ] 全サービス正常動作確認
- [ ] ヘルスチェック実行
- [ ] ユーザーアクセス確認
- [ ] バックアップ作成
- [ ] インシデント報告書作成
- [ ] 再発防止策検討

### 問い合わせ・サポート

#### 情報収集テンプレート

問題報告時は以下の情報を収集してください：

```bash
# システム情報
echo "=== システム情報 ==="
uname -a
cat /etc/os-release
docker --version
uptime

echo "=== リソース情報 ==="
free -h
df -h

echo "=== サービス状態 ==="
sudo systemctl status immich jellyfin docker

echo "=== ヘルスチェック ==="
./scripts/monitoring/health-check.sh --json

echo "=== 最新エラーログ ==="
sudo journalctl --priority=err --since "1 hour ago" --no-pager
```

#### エラーレポート形式

- **発生日時**: YYYY-MM-DD HH:MM:SS
- **症状**: 具体的な現象
- **影響範囲**: ユーザー・サービスへの影響
- **実行した対応**: 試行した解決方法
- **現在の状態**: 復旧状況
- **添付ログ**: エラーログ・スクリーンショット
