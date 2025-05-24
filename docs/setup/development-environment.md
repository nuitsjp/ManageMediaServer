# 開発環境構築（WSL）

Windows上のWSL2環境で開発・テスト環境を構築する手順を説明します。

## 前提条件

### Windows環境
- Windows 11 Pro（WSL2対応）
- Visual Studio Code

### WSL2セットアップ

```powershell
# WSL2有効化
wsl --install
wsl --set-default-version 2

# Ubuntu 22.04 LTS インストール
wsl --install -d Ubuntu-22.04
```

## 開発環境構成

```
Windows 11
├── d:\ManageMediaServer\          # Windowsファイルシステム（Git管理）
│   ├── ソースコード・設定ファイル
│   ├── ドキュメント
│   └── scripts/dev/              # 開発環境セットアップスクリプト
├── WSL2 (Ubuntu 22.04)
│   ├── /mnt/d/ManageMediaServer/  # Windows領域へのアクセス
│   ├── ~/dev-data/               # WSL固有の開発用データ
│   └── Docker CE                 # WSL内のネイティブDocker
└── Visual Studio Code
    └── Remote WSL拡張機能
```

**この構成の利点:**
- **Docker**: WSL内でネイティブ実行、軽量・高速
- **自動化**: セットアップスクリプトで一括構築
- **統合**: 本番環境との設定共通化

## セットアップ手順

### 1. Windowsでプロジェクトクローン

```powershell
# Windows PowerShell/Command Prompt
cd d:\
git clone <repository-url> ManageMediaServer
cd ManageMediaServer
```

### 2. 開発環境自動セットアップ

```bash
# WSL環境に入る
wsl -d Ubuntu-22.04

# プロジェクトにアクセス
cd /mnt/d/ManageMediaServer

# 開発環境セットアップスクリプト実行
./scripts/dev/setup-wsl.sh
```

### セットアップスクリプトが実行する内容

`scripts/dev/setup-wsl.sh` では以下を自動実行：

1. **システム更新・基本パッケージ**
   ```bash
   sudo apt update && sudo apt upgrade -y
   sudo apt install -y curl git htop tree jq
   ```

2. **Docker CE インストール**
   ```bash
   # Docker公式リポジトリ追加
   # Docker CE インストール
   # ユーザーをdockerグループに追加
   ```

3. **rclone インストール**
   ```bash
   curl https://rclone.org/install.sh | sudo bash
   ```

4. **開発用ディレクトリ作成**
   ```bash
   mkdir -p ~/dev-data/{data,backup}/{immich,jellyfin,temp}
   mkdir -p ~/dev-data/config/rclone/logs
   ```

5. **設定ファイル準備**
   ```bash
   cp docker/dev/.env.example docker/dev/.env
   cp config/rclone/rclone.conf.example ~/dev-data/config/rclone/rclone.conf
   ```

### 3. 開発用サービス起動

```bash
# 開発サービス起動
./scripts/dev/start-services.sh

# サービス確認
docker ps
```

## パフォーマンス最適化

### ファイル配置戦略

| ファイル種別 | 配置場所 | 理由 |
|-------------|----------|------|
| ソースコード | Windows | Git操作・編集が高速 |
| 設定ファイル | Windows | バージョン管理対象 |
| 実行時データ | WSL | Linux互換性が必要 |
| 一時ファイル | WSL | 頻繁な読み書きでも影響少 |

### .env設定例（WSL用）

```bash
# docker/dev/.env
# データパス（WSL側）
DATA_PATH=~/dev-data/data
BACKUP_PATH=~/dev-data/backup
CONFIG_PATH=~/dev-data/config

# ソースパス（Windows側）
SOURCE_PATH=/mnt/d/ManageMediaServer
```

## 開発用設定

### 自動設定内容

セットアップスクリプトにより以下が自動設定：

- **Docker設定**: WSL内でのネイティブDocker環境
- **rclone設定**: 開発用テスト設定
- **環境変数**: WSL環境に最適化されたパス設定
- **権限設定**: 必要なファイル・ディレクトリ権限

### VS Code設定

1. Remote WSL拡張機能インストール
2. WSL環境に接続
3. `/mnt/d/ManageMediaServer` フォルダを開く

### 手動設定（必要に応じて）

```bash
# rclone設定のカスタマイズ
rclone config

# 環境変数の調整
nano docker/dev/.env
```

## 開発ワークフロー

1. **Git操作**: Windows側（PowerShell/Command Prompt）
2. **コード編集**: VS Code (Remote WSL) で `/mnt/d/ManageMediaServer`
3. **サービス管理**: WSL環境で `./scripts/dev/start-services.sh` 等
4. **テスト実行**: WSL環境でDocker実行
5. **データ確認**: WSL側の `~/dev-data` を確認

## トラブルシューティング

### セットアップスクリプト失敗時

```bash
# ログ確認
cat ~/setup-wsl.log

# 手動修復後、再実行
./scripts/dev/setup-wsl.sh --force
```

### Docker権限問題

```bash
# dockerグループ確認・追加
sudo usermod -aG docker $USER
# WSL再起動が必要
exit
wsl --shutdown
wsl -d Ubuntu-22.04
```
