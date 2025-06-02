# 通知システム設定・使用ガイド

本ガイドでは、ホームメディアサーバーの通知システムの設定と使用方法について説明します。

## 概要

通知システムはDiscord Webhookを使用して、以下の状況で自動的にスマートフォンに通知を送信します：

- **ヘルスチェック結果**: システムの問題検出時
- **バックアップ状況**: バックアップの成功・失敗
- **デプロイ結果**: 本番環境へのデプロイ状況
- **セキュリティアラート**: 異常な活動の検出

## 1. 通知設定

### Discord Webhook設定

1. **Discord Webhookの作成**
   - Discordサーバーで「設定」→「インテグレーション」→「ウェブフック」
   - 「新しいウェブフック」を作成
   - ウェブフックURLをコピー

2. **通知設定スクリプト実行**
   ```bash
   # 対話式設定
   ./scripts/setup/setup-notification.sh --setup
   
   # URLを直接指定
   ./scripts/setup/setup-notification.sh --url "YOUR_WEBHOOK_URL"
   
   # 設定確認
   ./scripts/setup/setup-notification.sh --status
   ```

3. **テスト通知送信**
   ```bash
   ./scripts/setup/setup-notification.sh --test
   ```

## 2. 監視システム設定

### 自動監視の有効化

```bash
# 監視システム設定（管理者権限必要）
sudo ./scripts/setup/setup-monitoring.sh --setup

# 監視有効化
sudo ./scripts/setup/setup-monitoring.sh --enable

# 監視状態確認
./scripts/setup/setup-monitoring.sh --status
```

### 監視スケジュール

| 監視タイプ | 実行間隔 | 通知条件 | 説明 |
|------------|----------|----------|------|
| 基本ヘルスチェック | 5分毎 | エラー時のみ | 重要な問題の早期検出 |
| 詳細ヘルスチェック | 1時間毎 | 警告以上 | 包括的なシステム状態確認 |
| 日次レポート | 毎日8:00 | 全ての情報 | 日常の運用レポート |

## 3. 手動ヘルスチェック

### 基本的な使用方法

```bash
# 標準ヘルスチェック
./scripts/monitoring/health-check.sh

# 通知付きヘルスチェック（警告以上で通知）
./scripts/monitoring/health-check.sh --notify --threshold warning

# 詳細ヘルスチェック（通知付き）
./scripts/monitoring/health-check.sh --notify --detailed --threshold info

# レポート形式での実行
./scripts/monitoring/health-check.sh --report --notify
```

### 通知閾値

- `error`: 重大なエラー時のみ通知
- `warning`: 警告以上で通知（推奨）
- `info`: 全ての情報で通知

## 4. バックアップ通知

バックアップ操作時は自動的に通知が送信されます：

```bash
# バックアップ付きデプロイ（自動通知）
./scripts/prod/deploy.sh --backup

# ロールバック（自動通知）
./scripts/prod/deploy.sh --rollback
```

## 5. 通知の管理

### 通知の有効化・無効化

```bash
# 通知有効化
./scripts/setup/setup-notification.sh --enable

# 通知無効化
./scripts/setup/setup-notification.sh --disable

# 監視無効化（管理者権限）
sudo ./scripts/setup/setup-monitoring.sh --disable
```

### 設定ファイル

通知設定は `config/env/notification.env` に保存されます：

```bash
# Discord Webhook通知設定
DISCORD_WEBHOOK_URL="YOUR_WEBHOOK_URL"

# 通知設定
NOTIFICATION_ENABLED=true
NOTIFICATION_LEVEL="warning"
HEALTH_CHECK_NOTIFY_THRESHOLD="warning"
```

## 6. トラブルシューティング

### よくある問題

**1. 通知が送信されない**
```bash
# 設定確認
./scripts/setup/setup-notification.sh --status

# テスト通知
./scripts/setup/setup-notification.sh --test

# Discord Webhook URL確認
cat config/env/notification.env | grep DISCORD_WEBHOOK_URL
```

**2. 監視が動作しない**
```bash
# タイマー状態確認
./scripts/setup/setup-monitoring.sh --status

# systemdログ確認
sudo journalctl -u health-check-*.service -f
```

**3. 権限エラー**
```bash
# スクリプト実行権限付与
chmod +x scripts/setup/setup-*.sh
chmod +x scripts/monitoring/health-check.sh
```

### ログの確認

```bash
# 通知ログ確認
journalctl -u health-check-*.service -n 10

# 詳細ログ
journalctl -u health-check-detailed.service --since "1 hour ago"
```

## 7. カスタマイズ

### 通知メッセージのカスタマイズ

`scripts/lib/notification.sh` でメッセージ形式を変更できます。

### 監視間隔の変更

`scripts/setup/setup-monitoring.sh` のタイマー設定を編集：

```bash
# 例：基本チェックを10分毎に変更
OnCalendar=*:*/10
```

## 8. セキュリティ

- Discord Webhook URLは機密情報として管理
- 設定ファイルは適切な権限（600）で保護
- 本番環境では監視ログの定期クリーンアップを実施

## 参考リンク

- [Discord Webhook ドキュメント](https://discord.com/developers/docs/resources/webhook)
- [systemd Timer ドキュメント](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
- [ヘルスチェック詳細](../operations/README.md)
