# サーバー構成

## 統一論理構成

開発環境（WSL）と本番環境（Ubuntu Server）で同一の論理構成を使用します。

### 統一ディレクトリ構成

```
${PROJECT_ROOT}/            # プロジェクトルート
├── docs/                   # ドキュメント
├── docker/                 # Docker Compose設定
│   ├── dev/               # 開発環境用
│   └── prod/              # 本番環境用
├── config/                 # 設定ファイル・テンプレート
├── scripts/               # 運用スクリプト
│   ├── setup/             # セットアップスクリプト（共通）
│   ├── dev/               # 開発環境固有
│   └── prod/              # 本番環境固有
└── README.md

${DATA_ROOT}/               # データルート（環境変数で指定）
├── immich/                 # Immich外部ライブラリ
│   ├── photos/
│   └── videos/
├── jellyfin/               # Jellyfinライブラリ
│   └── movies/
├── temp/                   # 一時作業領域
│   ├── upload/
│   └── processing/
└── config/                 # 実行時設定
    └── rclone/
        ├── rclone.conf
        └── logs/

${BACKUP_ROOT}/             # バックアップルート（環境変数で指定）
├── media/                  # メディアバックアップ
├── config/                 # 設定バックアップ
└── system/                 # システムバックアップ
```

### 環境別パス設定

#### 開発環境（WSL）
```bash
# ~/.bashrc または .env
export PROJECT_ROOT="/mnt/d/ManageMediaServer"
export DATA_ROOT="$HOME/dev-data"
export BACKUP_ROOT="$HOME/dev-backup"
```

#### 本番環境（Ubuntu Server）
```bash
# /etc/environment または .env
export PROJECT_ROOT="/home/mediaserver/ManageMediaServer"
export DATA_ROOT="/mnt/data"
export BACKUP_ROOT="/mnt/backup"
```

## 物理構成（環境別）

### 開発環境（WSL）

```
Windows 11
├── d:\ManageMediaServer\          # Git管理領域
└── WSL2 (Ubuntu 22.04)
    ├── /mnt/d/ManageMediaServer/  # PROJECT_ROOT
    ├── ~/dev-data/                # DATA_ROOT
    └── ~/dev-backup/              # BACKUP_ROOT
```

### 本番環境（Ubuntu Server）

```
Ubuntu Server 22.04
├── /home/mediaserver/ManageMediaServer/  # PROJECT_ROOT
├── /mnt/data/                          # DATA_ROOT
└── /mnt/backup/                       # BACKUP_ROOT
```

#### プライマリディスク（高速SSD/NVMe）
- **PROJECT_ROOT**: `/home/mediaserver/ManageMediaServer`
- **DATA_ROOT**: `/mnt/data`
- **OS領域**: `/`, `/home`, `/var`

#### バックアップディスク（大容量HDD）
- **BACKUP_ROOT**: `/mnt/backup`

## 共通セットアップ手順

### 1. 基本環境準備
```bash
# Git インストール（環境により方法が異なる）
# 開発環境: WSLに含まれる
# 本番環境: sudo apt install git

# プロジェクトクローン
git clone <repository-url> ManageMediaServer
cd ManageMediaServer
```

### 2. 環境検出・自動セットアップ
```bash
# 自動環境検出・セットアップ
./scripts/setup/auto-setup.sh
```

セットアップスクリプトが自動判定：
- WSL環境 → 開発環境セットアップ
- Ubuntu Server → 本番環境セットアップ
- その他 → エラー表示

### 3. 共通処理内容
1. 環境変数設定（パスの差分を吸収）
2. 必要パッケージインストール
3. Docker環境構築
4. rclone設定
5. ディレクトリ構成作成
6. 権限設定

## 統一の利点

### 開発効率
- 開発環境でテストした設定がそのまま本番適用可能
- 環境差分によるトラブル最小化

### 運用効率
- スクリプト・設定の一元管理
- ドキュメント維持コスト削減

### 学習効率
- 覚える構成が一つだけ
- 新メンバーのオンボーディング簡素化
