# AGENTS.md

このリポジトリで Codex が作業する際の運用ルールです。

## 基本方針

1. まず作業計画を立案し、利用者と内容をすり合わせて合意する。
2. 計画合意前は、原則としてファイル変更や本番環境への変更を行わない。
3. 計画合意後は、可能な限り自律的に調査、実装、検証、反映まで進める。

## 本番配置の運用境界

- `/home/ubuntu/repos/ManageMediaServer` を Git 管理される作業コピー、変更元とする。
- `/home/mediaserver/ManageMediaServer` を systemd や Docker Compose が参照する本番配置コピーとする。
- 本番配置コピーを直接編集して正としない。変更は作業コピーで行い、commit 可能な状態にする。
- 本番配置への管理ファイル反映は `scripts/ops/deploy-managed-files.sh` を使う。
- `deploy-managed-files.sh` は Git 管理対象の運用ファイルだけを反映し、`.env`、`config/env/*.env`、`config/rclone/rclone.conf`、ログ、`/mnt/data`、`/mnt/backup` を上書きしない。
- systemd unit/timer を変更した場合も、まず作業コピーを更新し、`deploy-managed-files.sh` で `/home/mediaserver/ManageMediaServer` と `/etc/systemd/system` へ反映する。

## 利用者作業が必要な場合

`sudo` が必要な操作など、利用者に実行を依頼する必要がある場合は、手順を個別コマンド列で渡さない。

- 依頼する作業は、使い捨ての 1 つの `.sh` スクリプトにまとめる。
- スクリプトはリポジトリ内に作成し、利用者にはその 1 ファイルの実行だけを依頼する。
- スクリプトには `set -euo pipefail` を設定し、対象ファイルの存在確認、バックアップ、実行結果の表示を含める。
- 実行後に不要になるスクリプトや一時作業ファイルは、作業終了後に必ず削除する。

## 完了処理

作業が完了したら、可能な限り以下まで行う。

1. 対応した GitHub Issue に結果を反映する。
2. Issue を close する。
3. 変更を git commit する。
4. branch を push する。

Issue 反映、close、commit、push が権限や環境の都合で実行できない場合は、何が未実施かを明確に報告する。
