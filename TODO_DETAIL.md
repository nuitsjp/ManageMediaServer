### 次の実装タスク

#### タスク3.1: セキュリティ設定の強化 🔒 ✅ **基本実装完了**

**実装済み**:
- ✅ **WSL環境でのセキュリティテスト機能** - `setup-prod.sh` に `--test-mode` オプション追加
- ✅ **fail2ban設定強化** - 家庭内IP除外設定（192.168.0.0/16）
- ✅ **SSH設定改良** - 認証試行制限とロールバック機能
- ✅ **ファイアウォール設定** - 家庭内ネットワーク制限
- ✅ **セキュリティチェックスクリプト** - `security-check.sh` 作成済み

**実装詳細**:

1. **ファイアウォール設定の自動化強化** ✅ **完了**
   - 対象ファイル: `scripts/setup/setup-prod.sh`
   - 実装済み内容:
     ```bash
     # 家庭内ネットワーク制限（192.168.0.0/16）
     # UFW基本設定（incoming deny, outgoing allow）
     # SSH、Immich、Jellyfin ポート許可
     # テストモード対応（WSL環境での事前確認）
     ```

2. **ユーザー権限設定の自動化** ✅ **基本完了**
   - 対象ファイル: `scripts/lib/system.sh` の `setup_mediaserver_user()` 関数
   - 実装済み内容:
     ```bash
     # mediaserverユーザー作成
     # dockerグループ追加
     # ディレクトリ所有権設定
     ```

3. **SSH設定の強化** ✅ **完了**
   - 対象ファイル: `scripts/setup/setup-prod.sh` の `setup_ssh_security()` 関数
   - 実装済み内容:
     ```bash
     # PermitRootLogin no
     # MaxAuthTries 3
     # 設定バックアップ・ロールバック機能
     # テストモード対応
     ```

**次の実行手順**:
```bash
# 1. WSL環境でセキュリティ設定テスト（推奨）
./scripts/setup/auto-setup.sh --test-mode --security-only

# 2. 本番環境でセキュリティ設定適用
./scripts/setup/auto-setup.sh --security-only

# 3. 設定確認
sudo ufw status verbose
sudo fail2ban-client status
./scripts/setup/security-check.sh
```

#### タスク3.2: セキュリティ設定の実践テスト 🧪 **次のステップ**

**WSL環境での事前テスト実施**:
1. **セキュリティテストモード実行**
   ```bash
   # WSL環境に接続
   wsl -d Ubuntu-24.04
   cd /mnt/d/ManageMediaServer
   
   # セキュリティ設定をテストモードで確認
   ./scripts/setup/setup-prod.sh --test-mode --security-only
   ```

2. **テスト結果検証**
   - ファイアウォール設定内容の確認
   - fail2ban設定の妥当性チェック
   - SSH設定変更内容の確認
   - 家庭内ネットワーク制限の適切性確認

3. **本番環境での適用準備**
   ```bash
   # 本番環境（Ubuntu Server）で実行
   ./scripts/setup/setup-prod.sh --security-only
   
   # 設定状態確認
   sudo ufw status verbose
   sudo fail2ban-client status sshd
   sudo sshd -T | grep -E "(PermitRootLogin|MaxAuthTries)"
   ```

#### タスク3.3: セキュリティ監視の強化 🛡️ **将来実装**

**追加実装予定**:
1. **詳細ログ監視**
   - 対象ファイル: `scripts/setup/security-check.sh` 拡張
   - 実装内容:
     ```bash
     # SSH攻撃パターン検出
     # 異常なトラフィック監視
     # システムリソース監視との連携
     ```

2. **自動通知システム**
   - 実装内容:
     ```bash
     # セキュリティアラート通知
     # 定期セキュリティレポート
     # 家庭内デバイス接続監視
     ```

3. **高度なファイアウォール設定**
   - 実装内容:
     ```bash
     # 地理的ブロック（fail2ban連携）
     # レート制限設定
     # DDoS対策基本設定
     # アプリケーション層フィルタリング
     ```

#### 重要な注意事項 ⚠️

**家庭内環境前提**:
- 本実装は家庭内クローズドネットワーク環境を前提
- 192.168.0.0/16 ネットワークからのアクセスを信頼
- パスワード認証を家庭内利便性のため維持
- 商用環境では追加のセキュリティ強化が必要

**WSLテストモードの制限**:
- 実際のシステム設定変更は行わない
- 設定内容の妥当性確認のみ
- 本番適用前の事前検証用途

