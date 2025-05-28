# セキュリティ設定テストガイド

このドキュメントでは、本番環境での安全なセキュリティ設定適用のために、WSL環境でのセキュリティ設定事前テストの実行方法について説明します。

## 概要

### なぜテストが必要か

家庭用メディアサーバーのセキュリティ設定は、以下の理由で事前テストが重要です：

- **設定ミスの回避**: SSH設定やファイアウォール設定のミスによるアクセス不能状態の回避
- **家庭内環境の特殊性**: 一般的なセキュリティ設定と家庭内利便性のバランス確認
- **設定内容の確認**: 実際に適用される設定の詳細な事前確認

### テスト環境と本番環境

| 項目 | WSL環境（テスト） | Ubuntu Server（本番） |
|------|------------------|---------------------|
| セキュリティ設定実行 | シミュレーション | 実際の適用 |
| ファイアウォール | ログ出力のみ | UFW設定変更 |
| fail2ban | ログ出力のみ | サービス設定 |
| SSH設定 | ログ出力のみ | 設定ファイル変更 |

## セキュリティテストの実行

### 1. WSL環境でのセキュリティ設定テスト

```bash
# プロジェクトディレクトリに移動
cd /mnt/d/ManageMediaServer

# セキュリティ設定テストモードで実行
./scripts/setup/auto-setup.sh --test-security
```

### 2. 個別スクリプトでのテスト

```bash
# 本番環境セットアップスクリプトを直接テストモードで実行
./scripts/setup/setup-prod.sh --test-mode --security-only
```

### 3. テスト出力例

```
[INFO] セキュリティ設定テストモードが有効になりました
[WARN] WSL環境でセキュリティ設定をテスト実行します
[INFO] セキュリティ設定のみを実行します
[INFO] テストモード有効: WSL環境でのセキュリティ設定をシミュレーション実行
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
[WARN] [テストモード] 実際のファイアウォール設定は実行されていません
[INFO] fail2ban設定を適用中...
[INFO] [テストモード] fail2ban設定をシミュレーション実行中...
[INFO] [SKIP] fail2banパッケージインストール
[INFO] [SKIP] jail.local設定作成（家庭内IP 192.168.0.0/16 除外）
[INFO] [SKIP] fail2banサービス再起動
[WARN] [テストモード] 実際のfail2ban設定は実行されていません
[SUCCESS] [テストモード] セキュリティ設定シミュレーション完了
[WARN] 実際の設定適用は本番環境で --test-mode を外して実行してください
```

## 設定内容の確認ポイント

### ファイアウォール設定

テスト実行時に確認すべき設定：

```bash
# 実際に適用される設定内容
sudo ufw default deny incoming          # 受信拒否（デフォルト）
sudo ufw default allow outgoing         # 送信許可（デフォルト）
sudo ufw allow ssh                      # SSH許可
sudo ufw allow from 192.168.0.0/16 to any port 2283  # Immich（家庭内のみ）
sudo ufw allow from 192.168.0.0/16 to any port 8096  # Jellyfin（家庭内のみ）
```

**確認ポイント**:
- 家庭内ネットワーク（192.168.0.0/16）からのみアクセス許可
- SSH接続は維持（リモート管理用）
- 外部からの直接アクセスは基本的に拒否

### fail2ban設定

```bash
# 家庭内IP除外設定
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16

# SSH接続制限
maxretry = 3        # 3回失敗でブロック
findtime = 600      # 10分間での試行回数
bantime = 3600      # 1時間ブロック
```

**確認ポイント**:
- 家庭内IPアドレスは監視対象外
- 適度な制限値（利便性とセキュリティのバランス）

### SSH設定

```bash
# 適用される設定
PermitRootLogin no              # root直接ログイン禁止
PasswordAuthentication yes      # パスワード認証許可（家庭内利便性考慮）
MaxAuthTries 3                  # 認証試行制限
```

**確認ポイント**:
- rootログイン禁止は維持
- パスワード認証は家庭内利便性のため許可
- 認証試行制限で無差別攻撃対策

## 本番環境での実行

テスト結果に問題がなければ、本番環境で実際の設定を適用します：

### 1. 本番環境での完全セットアップ

```bash
# Ubuntu Serverで実行
./scripts/setup/auto-setup.sh
```

### 2. セキュリティ設定のみ適用

```bash
# セキュリティ設定のみ実行
./scripts/setup/setup-prod.sh --security-only
```

### 3. 設定確認

```bash
# ファイアウォール状態確認
sudo ufw status verbose

# fail2ban状態確認
sudo fail2ban-client status
sudo fail2ban-client status sshd

# SSH設定確認
sudo sshd -T | grep -E "(PermitRootLogin|PasswordAuthentication|MaxAuthTries)"
```

## トラブルシューティング

### SSH接続ができなくなった場合

```bash
# 設定バックアップからの復元
sudo cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
sudo systemctl restart ssh
```

### ファイアウォールでブロックされた場合

```bash
# 物理アクセスまたはコンソール経由で実行
sudo ufw disable
sudo ufw --force reset
```

### fail2banでブロックされた場合

```bash
# IP確認・解除
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip [IPアドレス]
```

## セキュリティ監視

設定適用後の継続的な監視：

```bash
# セキュリティチェックスクリプト実行
./scripts/setup/security-check.sh

# ヘルスチェック実行
./scripts/monitoring/health-check.sh --detailed
```

## 注意事項

1. **バックアップの重要性**: 設定変更前は必ずバックアップを作成
2. **段階的適用**: 一度にすべての設定を変更せず、段階的に適用
3. **アクセス手段の確保**: SSH設定変更時は別のアクセス手段を確保
4. **家庭内環境特化**: 本設定は家庭内クローズドネットワーク前提
5. **定期的な見直し**: セキュリティ設定は定期的に見直し・更新

## 関連ドキュメント

- [システム構成](../design/system-architecture.md)
- [運用ガイド](README.md)
- [トラブルシューティング](troubleshooting.md)
