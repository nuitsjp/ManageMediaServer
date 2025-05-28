# バックアップ手順

本番環境におけるバックアップの作成、管理、復元手順について説明します。

## 目次

1. [バックアップ戦略](#バックアップ戦略)
2. [自動バックアップ](#自動バックアップ)
3. [手動バックアップ](#手動バックアップ)
4. [復元手順](#復元手順)
5. [バックアップ検証](#バックアップ検証)
6. [災害復旧](#災害復旧)

## バックアップ戦略

### バックアップ対象

| 項目 | パス | 重要度 | 頻度 |
|------|------|---------|------|
| 設定ファイル | `docker/`, `config/` | 高 | デプロイ時 |
| データベース | Immich Postgres | 高 | 日次 |
| アプリケーションデータ | `/mnt/data/immich`, `/mnt/data/jellyfin` | 中 | 週次 |
| メディアファイル | 外部ライブラリ | 低 | 月次 |
| システム設定 | `/etc/systemd`, `/etc/docker` | 中 | 月次 |

### バックアップ保持ポリシー

- **デプロイバックアップ**: 最新5回分
- **日次バックアップ**: 7日分
- **週次バックアップ**: 4週分
- **月次バックアップ**: 12ヶ月分

### ストレージ構成

```
/mnt/backup/
├── deploy_backup_*/        # デプロイ時バックアップ
├── daily_backup_*/         # 日次バックアップ
├── weekly_backup_*/        # 週次バックアップ
├── monthly_backup_*/       # 月次バックアップ
├── system_backup_*/        # システムバックアップ
└── .backup_metadata        # バックアップメタデータ
```

## 自動バックアップ

### デプロイ前自動バックアップ

デプロイスクリプトに組み込まれた自動バックアップ：

```bash
# バックアップ付きデプロイ
./scripts/prod/deploy.sh --backup
```

**バックアップ内容:**
- Docker Compose設定
- 環境変数ファイル
- Immichデータベース
- バックアップメタデータ

### 定期自動バックアップ設定

#### cronジョブ設定

```bash
# crontab編集
sudo crontab -e

# 以下を追加
# 日次バックアップ（毎日 2:00AM）
0 2 * * * /home/mediaserver/ManageMediaServer/scripts/backup/daily-backup.sh

# 週次バックアップ（毎週日曜 3:00AM）
0 3 * * 0 /home/mediaserver/ManageMediaServer/scripts/backup/weekly-backup.sh

# 月次バックアップ（毎月1日 4:00AM）
0 4 1 * * /home/mediaserver/ManageMediaServer/scripts/backup/monthly-backup.sh

# バックアップクリーンアップ（毎日 5:00AM）
0 5 * * * /home/mediaserver/ManageMediaServer/scripts/backup/cleanup-backups.sh
```

#### systemdタイマー設定（推奨）

```bash
# タイマー設定確認
sudo systemctl list-timers --all | grep backup

# タイマー有効化
sudo systemctl enable backup-daily.timer
sudo systemctl enable backup-weekly.timer
sudo systemctl enable backup-monthly.timer
sudo systemctl start backup-daily.timer
sudo systemctl start backup-weekly.timer
sudo systemctl start backup-monthly.timer
```

## 手動バックアップ

### フル設定バックアップ

```bash
#!/bin/bash
# フル設定バックアップスクリプト

backup_date=$(date '+%Y%m%d_%H%M%S')
backup_dir="/mnt/backup/manual_backup_$backup_date"

echo "フルバックアップを作成中: $backup_dir"

# バックアップディレクトリ作成
mkdir -p "$backup_dir"/{config,data,system}

# 設定ファイルバックアップ
echo "設定ファイルをバックアップ中..."
cp -r "$PROJECT_ROOT/docker" "$backup_dir/config/"
cp -r "$PROJECT_ROOT/config" "$backup_dir/config/"
cp "$PROJECT_ROOT/.env" "$backup_dir/config/" 2>/dev/null || true

# データベースバックアップ
echo "データベースをバックアップ中..."
docker exec immich_postgres pg_dump -U postgres immich > "$backup_dir/data/immich_db.sql"

# システム設定バックアップ
echo "システム設定をバックアップ中..."
sudo cp -r /etc/systemd/system/immich.service "$backup_dir/system/" 2>/dev/null || true
sudo cp -r /etc/systemd/system/jellyfin.service "$backup_dir/system/" 2>/dev/null || true
sudo cp /etc/docker/daemon.json "$backup_dir/system/" 2>/dev/null || true

# メタデータ作成
echo "backup_date=$backup_date" > "$backup_dir/backup_info.txt"
echo "backup_type=manual_full" >> "$backup_dir/backup_info.txt"
echo "project_root=$PROJECT_ROOT" >> "$backup_dir/backup_info.txt"
echo "git_commit=$(git rev-parse HEAD 2>/dev/null || echo 'unknown')" >> "$backup_dir/backup_info.txt"
echo "docker_images=$(docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}' | grep -E '(immich|jellyfin)')" >> "$backup_dir/backup_info.txt"

# バックアップ完了
echo "フルバックアップ完了: $backup_dir"
ls -la "$backup_dir"
```

### データベースのみバックアップ

```bash
#!/bin/bash
# データベースバックアップスクリプト

backup_date=$(date '+%Y%m%d_%H%M%S')
backup_file="/mnt/backup/immich_db_backup_$backup_date.sql"

echo "データベースバックアップを作成中: $backup_file"

# Immichデータベースバックアップ
docker exec immich_postgres pg_dump -U postgres immich > "$backup_file"

# 圧縮
gzip "$backup_file"

echo "データベースバックアップ完了: ${backup_file}.gz"
```

### 設定ファイルのみバックアップ

```bash
#!/bin/bash
# 設定ファイルバックアップスクリプト

backup_date=$(date '+%Y%m%d_%H%M%S')
backup_file="/mnt/backup/config_backup_$backup_date.tar.gz"

echo "設定ファイルバックアップを作成中: $backup_file"

# 設定ファイル圧縮バックアップ
cd "$PROJECT_ROOT"
tar -czf "$backup_file" docker/ config/ .env 2>/dev/null || tar -czf "$backup_file" docker/ config/

echo "設定ファイルバックアップ完了: $backup_file"
```

## 復元手順

### デプロイバックアップからの復元

```bash
# 1. 最新のデプロイバックアップを確認
ls -la /mnt/backup/deploy_backup_*/

# 2. 復元実行
./scripts/prod/deploy.sh --rollback
```

### 手動復元

#### 設定ファイル復元

```bash
#!/bin/bash
# 設定ファイル復元スクリプト

backup_dir="/mnt/backup/manual_backup_YYYYMMDD_HHMMSS"

if [ ! -d "$backup_dir" ]; then
    echo "エラー: バックアップディレクトリが見つかりません: $backup_dir"
    exit 1
fi

echo "設定ファイルを復元中..."

# サービス停止
sudo systemctl stop immich jellyfin

# 現在の設定をバックアップ
current_backup="/tmp/current_config_$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$current_backup"
cp -r docker config "$current_backup/" 2>/dev/null || true

# 設定復元
cp -r "$backup_dir/config/docker" ./
cp -r "$backup_dir/config/config" ./
cp "$backup_dir/config/.env" ./ 2>/dev/null || true

# システム設定復元
if [ -d "$backup_dir/system" ]; then
    sudo cp "$backup_dir/system/immich.service" /etc/systemd/system/ 2>/dev/null || true
    sudo cp "$backup_dir/system/jellyfin.service" /etc/systemd/system/ 2>/dev/null || true
    sudo cp "$backup_dir/system/daemon.json" /etc/docker/ 2>/dev/null || true
    sudo systemctl daemon-reload
fi

# サービス開始
sudo systemctl start immich jellyfin

echo "設定ファイル復元完了"
echo "現在の設定バックアップ: $current_backup"
```

#### データベース復元

```bash
#!/bin/bash
# データベース復元スクリプト

backup_file="/mnt/backup/immich_db_backup_YYYYMMDD_HHMMSS.sql"

if [ ! -f "$backup_file" ]; then
    # gzip圧縮版確認
    if [ -f "${backup_file}.gz" ]; then
        echo "圧縮ファイルを解凍中..."
        gunzip "${backup_file}.gz"
    else
        echo "エラー: バックアップファイルが見つかりません: $backup_file"
        exit 1
    fi
fi

echo "データベースを復元中..."

# 現在のデータベースバックアップ
current_backup="/tmp/immich_current_$(date '+%Y%m%d_%H%M%S').sql"
docker exec immich_postgres pg_dump -U postgres immich > "$current_backup"

# データベース復元
cat "$backup_file" | docker exec -i immich_postgres psql -U postgres immich

echo "データベース復元完了"
echo "現在のデータベースバックアップ: $current_backup"
```

## バックアップ検証

### バックアップ整合性チェック

```bash
#!/bin/bash
# バックアップ検証スクリプト

backup_dir="/mnt/backup/deploy_backup_LATEST"

echo "バックアップ検証中: $backup_dir"

# バックアップディレクトリ存在確認
if [ ! -d "$backup_dir" ]; then
    echo "エラー: バックアップディレクトリが存在しません"
    exit 1
fi

# 必須ファイル確認
required_files=(
    "backup_info.txt"
    "config/docker"
    "config/config"
)

for file in "${required_files[@]}"; do
    if [ ! -e "$backup_dir/$file" ]; then
        echo "警告: 必須ファイルが見つかりません: $file"
    else
        echo "OK: $file"
    fi
done

# データベースバックアップ確認
if [ -f "$backup_dir/data/immich_db.sql" ]; then
    db_size=$(stat -f%z "$backup_dir/data/immich_db.sql" 2>/dev/null || stat -c%s "$backup_dir/data/immich_db.sql")
    if [ "$db_size" -gt 1000 ]; then
        echo "OK: データベースバックアップ (${db_size} bytes)"
    else
        echo "警告: データベースバックアップが小さすぎます (${db_size} bytes)"
    fi
else
    echo "警告: データベースバックアップが見つかりません"
fi

# メタデータ確認
if [ -f "$backup_dir/backup_info.txt" ]; then
    echo "バックアップ情報:"
    cat "$backup_dir/backup_info.txt"
else
    echo "警告: バックアップ情報ファイルが見つかりません"
fi

echo "バックアップ検証完了"
```

### 復元テスト

```bash
#!/bin/bash
# 復元テストスクリプト（開発環境用）

backup_dir="/mnt/backup/deploy_backup_LATEST"
test_dir="/tmp/restore_test_$(date '+%Y%m%d_%H%M%S')"

echo "復元テスト実行中: $test_dir"

# テスト環境作成
mkdir -p "$test_dir"
cd "$test_dir"

# バックアップファイル復元
cp -r "$backup_dir/config/docker" ./
cp -r "$backup_dir/config/config" ./

# Docker Compose設定検証
if [ -f "docker/immich/docker-compose.yml" ]; then
    docker-compose -f docker/immich/docker-compose.yml config --quiet
    if [ $? -eq 0 ]; then
        echo "OK: Immich Docker Compose設定"
    else
        echo "エラー: Immich Docker Compose設定に問題があります"
    fi
fi

if [ -f "docker/jellyfin/docker-compose.yml" ]; then
    docker-compose -f docker/jellyfin/docker-compose.yml config --quiet
    if [ $? -eq 0 ]; then
        echo "OK: Jellyfin Docker Compose設定"
    else
        echo "エラー: Jellyfin Docker Compose設定に問題があります"
    fi
fi

# クリーンアップ
rm -rf "$test_dir"

echo "復元テスト完了"
```

## 災害復旧

### 完全システム復旧手順

#### 1. 新システム準備

```bash
# 1. Ubuntu Server インストール
# 2. 基本システムセットアップ
sudo apt update && sudo apt upgrade -y

# 3. 必要パッケージインストール
sudo apt install -y git curl docker.io docker-compose

# 4. ユーザー設定
sudo usermod -aG docker $USER
```

#### 2. プロジェクト復元

```bash
# 1. リポジトリクローン
git clone <repository-url> ManageMediaServer
cd ManageMediaServer

# 2. バックアップから設定復元
backup_dir="/mnt/backup/monthly_backup_LATEST"
cp -r "$backup_dir/config/docker" ./
cp -r "$backup_dir/config/config" ./
cp "$backup_dir/config/.env" ./ 2>/dev/null || true
```

#### 3. データ復元

```bash
# 1. データディレクトリ作成
sudo mkdir -p /mnt/data /mnt/backup
sudo chown $USER:$USER /mnt/data /mnt/backup

# 2. データベース復元準備
docker-compose -f docker/immich/docker-compose.yml up -d immich_postgres
sleep 30

# 3. データベース復元
cat "$backup_dir/data/immich_db.sql" | docker exec -i immich_postgres psql -U postgres -d immich

# 4. サービス起動
docker-compose -f docker/immich/docker-compose.yml up -d
docker-compose -f docker/jellyfin/docker-compose.yml up -d
```

#### 4. システム設定復元

```bash
# 1. systemdサービス復元
sudo cp "$backup_dir/system/immich.service" /etc/systemd/system/
sudo cp "$backup_dir/system/jellyfin.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable immich jellyfin

# 2. Docker設定復元
sudo cp "$backup_dir/system/daemon.json" /etc/docker/
sudo systemctl restart docker

# 3. 動作確認
sudo systemctl start immich jellyfin
./scripts/monitoring/health-check.sh
```

### 緊急時連絡先・手順

#### システム管理者連絡先
- 管理者: [管理者名]
- 緊急連絡先: [電話番号/メール]

#### 緊急時チェックリスト

1. **システム状態確認**
   - [ ] サーバー電源状態
   - [ ] ネットワーク接続
   - [ ] ディスク状態

2. **サービス状態確認**
   - [ ] Docker デーモン
   - [ ] Immich サービス
   - [ ] Jellyfin サービス

3. **データ確認**
   - [ ] データディスク状態
   - [ ] バックアップ可用性
   - [ ] データベース整合性

4. **復旧判断**
   - [ ] 部分復旧可能性
   - [ ] 完全復旧必要性
   - [ ] データ損失範囲

#### エスカレーション手順

1. **Level 1**: 自動復旧試行
2. **Level 2**: 手動復旧実行
3. **Level 3**: 完全復旧実行
4. **Level 4**: 専門技術者連絡

## バックアップ運用チェックリスト

### 日次チェック
- [ ] 自動バックアップ成功確認
- [ ] バックアップログ確認
- [ ] ディスク容量確認

### 週次チェック
- [ ] バックアップ整合性検証
- [ ] 古いバックアップクリーンアップ
- [ ] 復元テスト実行

### 月次チェック
- [ ] 災害復旧手順見直し
- [ ] バックアップ戦略評価
- [ ] ドキュメント更新

### 年次チェック
- [ ] 完全災害復旧テスト
- [ ] バックアップ保持ポリシー見直し
- [ ] ハードウェア交換計画確認
