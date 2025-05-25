# auto-setup.sh 段階的検証TODO

## 検証スタイル・手順 📝

### 基本的な検証アプローチ
1. **段階的コメントアウト**: auto-setup.shで検証対象外の処理を段階的にコメントアウト
2. **実際の実行**: `--dry-run`での確認後、実際にスクリプトを実行して動作確認
3. **結果検証**: ログ確認後、実際にコマンドを実行してインストール状況を確認
4. **段階的解除**: 検証完了後、次の処理のコメントを解除して進行

### 検証環境
- **環境**: WSL開発環境 (dev)
- **権限**: sudo権限で実行
- **ベースコマンド**: `cd /mnt/d/ManageMediaServer && sudo ./scripts/setup/auto-setup.sh --force`

---

## Phase 1: 基本機能確認 📋 ✅ **完了**

### 完了済み
- [x] **ライブラリ読み込み・環境判定確認** ✅
  - WSL環境が正しく `dev` として判定
  - 全ライブラリファイルが正常に読み込み
  - 環境変数(PROJECT_ROOT, DATA_ROOT, BACKUP_ROOT)が適切に設定

---

## Phase 2: システム基盤確認 🔧 ✅ **完了**

### 完了済み
- [x] **Dockerインストール前処理（Step 1-4）** ✅
  - 事前チェック、ディレクトリ準備、設定ファイル展開、システムパッケージインストール全て成功
  - 必要なディレクトリ(/root/dev-data/*)とファイルが適切に作成
  - curl, wget, git, apt-transport-https, ca-certificates, gnupg, lsb-release全てインストール確認済み

- [x] **Dockerインストール（Step 5）** ✅
  - Docker CE 26.1.3インストール完了
  - systemdでのdocker自動起動設定完了（enabled）
  - WSL環境用の適切なDocker設定適用
  - 冪等性実装により、既存設定の完全クリーンアップも正常動作
  - Hello-worldコンテナテストも成功

**検証結果:**
```bash
Docker version 26.1.3, build 26.1.3-0ubuntu1~24.04.1
● docker.service - Docker Application Container Engine (active/running)
enabled
```

---

## Phase 3: アプリケーション確認 🎯

### 必須
- [ ] **Immich + Jellyfin セットアップ（Step 6-7）**
  - Docker Compose構成作成
  - 各アプリケーションのセットアップ実行
  - サービス起動確認

**検証:** WebUIアクセス確認（Immich: http://localhost:2283, Jellyfin: http://localhost:8096）

---

## Phase 4: 外部サービス確認 🌐

### 必須
- [ ] **rclone・systemdサービス（Step 8-9）**
  - rcloneインストール確認
  - 本番環境でのsystemdサービス設定確認（devでは対象外）

---

## Phase 5: 完全実行確認 ✅

### 必須
- [ ] **エンドツーエンド検証**
  - 全ステップを有効にして完全実行
  - 全サービスの同時起動・動作確認
