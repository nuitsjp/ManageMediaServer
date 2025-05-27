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
- [x] **ライブラリ読み込み・環境判定確認** ✅

---

## Phase 2: システム基盤確認 🔧 ✅ **完了**
- [x] **Dockerインストール前処理（Step 1-4）** ✅
- [x] **Dockerインストール（Step 5）** ✅

---

## Phase 3: アプリケーション確認 🎯 ✅ **完了**
- [x] **Docker Compose構成作成（Step 6）** ✅ **設計改善完了**
- [x] **Immich + Jellyfin セットアップ（Step 7）** ✅

---

## Phase 4A: rclone インストール 🌐 ✅ **完了**

### 必須
- [x] **rclone インストール確認（Step 8）** ✅

---

## Phase 4B: systemd サービス設定 ⚙️

### 必須（本番環境のみ）
- [ ] **systemd サービス設定（Step 9）**
  - setup_systemd_services 関数の動作確認
  - サービスファイル作成確認
  - タイマー設定確認
  - 開発環境では対象外（スキップ）

---

## Phase 5: 完全実行確認 ✅

### 必須
- [ ] **エンドツーエンド検証**
  - 全ステップを有効にして完全実行
  - 全サービスの同時起動・動作確認

---

## 📌 **現在の状況（2025/05/26時点）**

### 完了済みの作業
1. **Phase 1-2完了**: 基本機能・システム基盤の検証が完了
2. **Docker環境構築済み**: Docker CE 26.1.3が正常動作中
3. **設計方針修正**: validate_docker_installation関数削除により統一感を向上

### 次のスレッドでの作業手順
1. **Step 6有効化**: `auto-setup.sh`の121行目付近の`create_docker_compose_structure`のコメントを解除
2. **実行・検証**: `sudo ./scripts/setup/auto-setup.sh --force`でテスト実行
3. **結果確認**: docker/immich/, docker/jellyfin/ディレクトリが作成されるか確認

### 重要なファイル状況
- `auto-setup.sh`: Step 1-5は動作確認済み、Step 6以降はコメントアウト状態
- `docker.sh`: install_docker関数は冪等性付きで完成、validate関数は削除済み
- Docker環境: WSL用設定適用済み、systemd自動起動設定済み

### 検証環境情報
- **環境**: WSL開発環境（dev）
- **Docker**: 26.1.3 (systemd管理、自動起動enabled)
- **データルート**: /root/dev-data/
- **プロジェクトルート**: /mnt/d/ManageMediaServer/
