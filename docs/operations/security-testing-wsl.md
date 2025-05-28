# WSL環境でのセキュリティテスト手順

## 概要

WSL環境で本番環境のセキュリティ設定を事前にテストする手順を説明します。これにより、本番環境での作業前にセキュリティ設定の妥当性を確認できます。

## 前提条件

- WSL2 (Ubuntu 24.04) が設定済み
- プロジェクトが Windows側 `d:\ManageMediaServer` に配置済み
- WSL環境からプロジェクトにアクセス可能

## テスト実行手順

### 1. WSL環境への接続

```bash
# PowerShellから実行
wsl -d Ubuntu-24.04
```

### 2. プロジェクトディレクトリへ移動

```bash
cd /mnt/d/ManageMediaServer
```

### 3. セキュリティテストモード実行

```bash
# セキュリティ設定のテストモード実行
./scripts/setup/setup-prod.sh --test-mode --security-only --debug
```

### 4. 期待される出力例

テストモード実行時は以下のような出力が表示されます：

```
[INFO] テストモード有効: WSL環境でのセキュリティ設定をシミュレーション実行
[WARNING] WSL環境でテストモード実行中
[INFO] 実際のセキュリティ設定は本番環境で実行してください
[INFO] セキュリティ設定のみ実行します
[INFO] === セキュリティ設定 ===
[INFO] [テストモード] セキュリティ設定をシミュレーション実行中...
[INFO] === ファイアウォール設定 ===
[INFO] [テストモード] ファイアウォール設定をシミュレーション実行中...
[INFO] [SKIP] sudo ufw --force reset
[INFO] [SKIP] sudo ufw default deny incoming
[INFO] [SKIP] sudo ufw default allow outgoing
[INFO] [SKIP] sudo ufw allow ssh
[INFO] [SKIP] sudo ufw allow from 192.168.0.0/16 to any port 2283 comment 'Immich'
[INFO] [SKIP] sudo ufw allow from 192.168.0.0/16 to any port 8096 comment 'Jellyfin'
[INFO] [SKIP] sudo ufw --force enable
[WARNING] [テストモード] 実際のファイアウォール設定は実行されていません
[INFO] fail2ban設定を適用中...
[INFO] [テストモード] fail2ban設定をシミュレーション実行中...
[INFO] [SKIP] fail2banパッケージインストール
[INFO] [SKIP] jail.local設定作成（家庭内IP 192.168.0.0/16 除外）
[INFO] [SKIP] fail2banサービス再起動
[WARNING] [テストモード] 実際のfail2ban設定は実行されていません
[INFO] SSH設定を強化中...
[INFO] [テストモード] SSH設定強化をシミュレーション実行中...
[INFO] [SKIP] PermitRootLogin no 設定
[INFO] [SKIP] PasswordAuthentication yes 設定（家庭内アクセス考慮）
[INFO] [SKIP] MaxAuthTries 3 設定
[INFO] [SKIP] SSH設定テスト・サービス再起動
[WARNING] [テストモード] 実際のSSH設定は実行されていません
[SUCCESS] [テストモード] セキュリティ設定シミュレーション完了
[WARNING] 実際の設定適用は本番環境で --test-mode を外して実行してください
[SUCCESS] セキュリティ設定完了
```

## テスト結果の確認ポイント

### 1. ファイアウォール設定

- ✅ **家庭内ネットワーク制限**: `192.168.0.0/16` からのアクセスのみ許可
- ✅ **必要ポート開放**: SSH(22), Immich(2283), Jellyfin(8096)
- ✅ **デフォルトポリシー**: incoming deny, outgoing allow

### 2. fail2ban設定

- ✅ **家庭内IP除外**: `192.168.0.0/16` が除外対象に含まれる
- ✅ **SSH保護**: 3回失敗で1時間ブロック設定
- ✅ **適切なログ監視**: `/var/log/auth.log` 監視設定

### 3. SSH設定

- ✅ **root ログイン禁止**: `PermitRootLogin no`
- ✅ **認証試行制限**: `MaxAuthTries 3`
- ✅ **パスワード認証維持**: 家庭内利便性考慮で `PasswordAuthentication yes`

## 本番環境での適用

テストで問題がないことを確認後、本番環境で実際の設定を適用：

```bash
# Ubuntu Server環境で実行
./scripts/setup/setup-prod.sh --security-only

# 設定状態確認
sudo ufw status verbose
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

## トラブルシューティング

### エラー: "このスクリプトは本番環境でのみ実行可能です"

**原因**: `--test-mode` オプションが指定されていない

**解決**: コマンドに `--test-mode` を追加
```bash
./scripts/setup/setup-prod.sh --test-mode --security-only
```

### テストモードで実際の設定が実行される

**原因**: WSL環境判定に問題がある可能性

**解決**: 環境確認とデバッグモード実行
```bash
# 環境確認
grep -E "(Microsoft|WSL)" /proc/version

# デバッグモード実行
./scripts/setup/setup-prod.sh --test-mode --security-only --debug
```

## 関連ドキュメント

- [セキュリティ設定詳細](security-testing.md)
- [トラブルシューティング](troubleshooting.md)
- [開発環境構築](../setup/development-environment.md)

## 注意事項

- **テストモードの制限**: 実際のシステム設定変更は行わない
- **家庭内環境前提**: 192.168.0.0/16 ネットワークを信頼する設定
- **商用環境注意**: 商用環境では追加のセキュリティ強化が必要
