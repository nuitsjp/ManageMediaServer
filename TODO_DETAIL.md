# 詳細開発タスク手順書

## 現在のステータス
- **フェーズ1**: 基盤構築 ✅ **完了**
- **フェーズ2**: 開発環境検証 ✅ **完了**  
- **フェーズ3**: 本番環境対応 🚀 **進行中**

## フェーズ3: 本番環境対応 🚀

### 現在完了している項目
- ✅ `auto-setup.sh` 統合セットアップスクリプト実装完了
- ✅ 環境自動判定機能（WSL/Ubuntu Server）
- ✅ 基本インストール処理（Docker、rclone、システムパッケージ）
- ✅ ディレクトリ構成・権限設定
- ✅ `setup-prod.sh` 本番環境専用設定スクリプト

### 次の実装タスク

#### タスク3.1: セキュリティ設定の強化 🔒

**優先度**: 高  
**推定工数**: 2-3時間

**詳細手順**:

1. **ファイアウォール設定の自動化強化**
   - 対象ファイル: `scripts/lib/system.sh`
   - 実装内容:
     ```bash
     # より詳細なファイアウォールルール
     setup_advanced_firewall() {
         # 地理的ブロック（fail2ban連携）
         # レート制限設定
         # DDoS対策基本設定
     }
     ```

2. **ユーザー権限設定の自動化**
   - 対象ファイル: `scripts/lib/system.sh` の `setup_mediaserver_user()` 関数
   - 追加実装:
     ```bash
     # mediaserverユーザーのsudo権限制限
     # パスワードポリシー設定
     # SSH鍵認証の自動設定準備
     ```

3. **SSH設定の強化**
   - 対象ファイル: `scripts/setup/setup-prod.sh` の `setup_ssh_security()` 関数
   - 改善点:
     ```bash
     # SSH鍵認証強制
     # 非標準ポート設定オプション
     # ログイン試行制限強化
     ```

**テスト方法**:
```bash
# Ubuntu Server仮想環境で実行
./scripts/setup/auto-setup.sh --debug
sudo ufw status verbose
sudo fail2ban-client status
```

#### タスク3.2: 運用自動化スクリプト開発 🤖

**優先度**: 中  
**推定工数**: 4-5時間

**詳細手順**:

1. **本番デプロイスクリプト (`scripts/prod/deploy.sh`) の完成**
   - 現在の状態: 基本フレームワーク実装済み
   - 追加実装必要項目:
     ```bash
     # Blue-Green デプロイ機能
     create_backup() {
         # データベース・設定ファイルのバックアップ
         # Docker イメージのバックアップ
     }
     
     rollback_deployment() {
         # 失敗時の自動ロールバック
         # 設定ファイル復元
     }
     ```

2. **システム更新スクリプト (`scripts/maintenance/update-system.sh`) の完成**
   - 現在の状態: 基本フレームワーク実装済み
   - 追加実装必要項目:
     ```bash
     # Docker イメージ更新
     update_docker_images() {
         # immich/jellyfin の安全な更新
         # 更新前後の動作確認
     }
     
     # システムパッケージ更新
     update_system_packages() {
         # セキュリティアップデート優先
         # 再起動が必要な場合の処理
     }
     ```

3. **ヘルスチェックスクリプト (`scripts/monitoring/health-check.sh`) の完成**
   - 新規作成が必要
   - 実装項目:
     ```bash
     # システムリソース監視
     check_system_resources() {
         # CPU、メモリ、ディスク使用率
         # Docker コンテナ状態
     }
     
     # サービス可用性チェック
     check_service_availability() {
         # HTTP レスポンス確認
         # データベース接続確認
     }
     
     # JSON出力対応
     output_health_status() {
         # 監視システム連携用
     }
     ```

**テスト方法**:
```bash
# 本番デプロイテスト（ドライラン）
./scripts/prod/deploy.sh --dry-run --backup

# システム更新テスト
./scripts/maintenance/update-system.sh --check-only

# ヘルスチェックテスト
./scripts/monitoring/health-check.sh --json
```

#### タスク3.3: Ubuntu Server での実地テスト 🧪

**優先度**: 高  
**推定工数**: 3-4時間

**詳細手順**:

1. **テスト環境準備**
   ```bash
   # Ubuntu Server 24.04 LTS 仮想マシン準備
   # 最小インストール構成
   # ネットワーク設定（静的IP設定）
   ```

2. **自動セットアップの実行・検証**
   ```bash
   # Git リポジトリクローン
   git clone <repository-url> ManageMediaServer
   cd ManageMediaServer
   
   # セットアップ実行
   ./scripts/setup/auto-setup.sh
   
   # 検証
   ./scripts/setup/verify-setup.sh --start-containers
   ```

3. **ディスク構成・マウント設定の検証**
   - `/etc/fstab` 設定確認
   - マウントポイント (`/mnt/data`, `/mnt/backup`) の動作確認
   - 権限設定の確認

4. **systemdサービス動作確認**
   ```bash
   # サービス状態確認
   sudo systemctl status immich jellyfin
   
   # 自動起動設定確認
   sudo systemctl is-enabled immich jellyfin
   
   # ログ確認
   journalctl -u immich -u jellyfin --since "1 hour ago"
   ```

**成功基準**:
- セットアップスクリプトがエラーなく完了
- 全サービスが正常起動
- ブラウザから Immich (port 2283) と Jellyfin (port 8096) にアクセス可能
- systemd サービスが自動起動設定済み

#### タスク3.4: ドキュメント更新・統合 📚

**優先度**: 中  
**推定工数**: 2-3時間

**詳細手順**:

1. **統合セットアップガイド作成**
   - ファイル: `docs/setup/environment-setup.md`
   - 内容:
     ```markdown
     # 統合環境セットアップガイド
     
     ## 1. 環境判定と自動セットアップ
     ## 2. 手動セットアップ（トラブルシューティング用）
     ## 3. 本番環境固有の設定
     ## 4. セキュリティ設定の詳細
     ```

2. **環境変数管理ガイド追加**
   - ファイル: `docs/setup/environment-setup.md` に統合
   - 内容:
     ```markdown
     ## 環境変数管理
     
     ### 開発環境 (WSL)
     ### 本番環境 (Ubuntu Server)
     ### 物理パス設定方法
     ### 機密情報の管理
     ```

3. **既存ドキュメントの統合判断**
   - `docs/setup/development-environment.md` の内容確認
   - 重複部分の統合または削除

**作業手順**:
```bash
# 現在のドキュメント構造確認
find docs/ -name "*.md" -type f

# 新しいガイド作成
touch docs/setup/environment-setup.md

# 内容統合後、不要ファイル削除判断
```

### 直近1週間の作業計画

#### Day 1-2: セキュリティ設定強化 (タスク3.1)
- ファイアウォール設定の詳細化
- SSH設定強化の実装
- ユーザー権限管理の改善

#### Day 3-4: 運用自動化スクリプト (タスク3.2)
- デプロイスクリプトの完成
- ヘルスチェックスクリプトの新規作成
- システム更新スクリプトの改善

#### Day 5-6: 実地テスト (タスク3.3)
- Ubuntu Server環境でのテスト
- 問題点の洗い出しと修正
- 性能・安定性の確認

#### Day 7: ドキュメント整備 (タスク3.4)
- 統合ガイドの作成
- 既存ドキュメントの整理
- README.md の更新

### 完了後の成果物

#### 実装完了予定項目
- ✅ セキュリティが強化された本番環境自動セットアップ
- ✅ 本番運用に必要な全自動化スクリプト
- ✅ Ubuntu Server での動作実績
- ✅ 統合された包括的なドキュメント

#### 次フェーズ（フェーズ4）への準備
- Cloudflare連携の基盤準備完了
- rclone実運用設定の準備完了
- 監視・ログシステムの基盤準備完了

### 注意事項・リスク管理

1. **セキュリティテスト**
   - 各設定変更後は必ずセキュリティスキャン実行
   - fail2ban、ufw設定の動作確認

2. **バックアップ戦略**
   - 本番環境テスト前に必ずスナップショット作成
   - 設定ファイルのバージョン管理

3. **ロールバック準備**
   - 各スクリプトに `--rollback` オプション実装検討
   - 設定変更前の状態保存機能

### 進捗追跡

- [ ] **タスク3.1**: セキュリティ設定強化
- [ ] **タスク3.2**: 運用自動化スクリプト開発  
- [ ] **タスク3.3**: Ubuntu Server実地テスト
- [ ] **タスク3.4**: ドキュメント更新・統合

**目標**: 2025年6月第1週までにフェーズ3完了