# ManageMediaServer

家庭内メディアサーバーの運用台帳です。

このリポジトリは、Ubuntu 上で稼働している Immich、Jellyfin、rclone、Tailscale、通知まわりの設定と、日常運用に必要な最小限のスクリプトを管理します。

## 目的

この環境は、家庭内の写真・動画・ミュージックビデオを一元管理し、スマートフォンや PC から安全に閲覧できるようにするためのものです。

主な目的は以下です。

- スマートフォンやクラウドストレージ上の写真・短尺動画を Immich で管理する
- 長尺動画やミュージックビデオを Jellyfin で視聴する
- rclone でクラウドストレージからローカルへ同期する
- バックアップディスクへ重要データを分離して保管する
- Tailscale のプライベートネットワークを使い、ポート開放なしで外部アクセスを制御する
- 障害時に、サービス状態・ログ・データ配置をすぐ確認できる状態にする

## 提供サービス

| サービス | URL / 役割 | 用途 |
| --- | --- | --- |
| Immich | `http://<LAN IP>:2283` / `http://<Tailscale IP>:2283` | 写真・短尺動画の管理、外部ライブラリ参照 |
| Jellyfin | `http://<LAN IP>:8096` / `http://<Tailscale IP>:8096` | 長尺動画・ミュージックビデオの視聴 |
| rclone | `rclone-media-sync.timer` | クラウドストレージから `/mnt/data/immich/external` へ取り込み |
| メディアバックアップ | `media-backup.timer` | 写真・動画を物理別ドライブの `/mnt/backup` へ追加コピー |
| アプリ更新 | `media-app-update.timer` | Immich/Jellyfin を同一 major 内で日次更新し、major 更新は通知だけ行う |
| ヘルス監視 | `media-health-check.timer` | Immich/Jellyfin、rclone timer、ディスク空き容量を定期確認 |
| Tailscale | `100.x.x.x` または MagicDNS 名 | 家庭外からのアクセス経路 |
| Discord 通知 | 設定ファイル: `config/env/notification.env` | 監視・バックアップ結果通知 |

## 日常的な利用方法

### Immich

Immich は写真・短尺動画の管理に使います。

```bash
curl -I --max-time 5 http://127.0.0.1:2283
sudo systemctl status immich --no-pager
journalctl -u immich -n 100 --no-pager
```

Immich のデータ配置:

- アップロード領域: `/mnt/data/immich/upload`
- 外部ライブラリ: `/mnt/data/immich/external`
- PostgreSQL データ: `/mnt/data/immich/postgres`
- Compose: `/home/mediaserver/ManageMediaServer/docker/immich/docker-compose.yml`
- 実行時 env: `/home/mediaserver/ManageMediaServer/docker/immich/.env`

外部ライブラリは Compose で read-only mount しています。

```yaml
${EXTERNAL_PATH:-/tmp/empty}:/usr/src/app/external:ro
```

### Jellyfin

Jellyfin は長尺動画・ミュージックビデオの視聴に使います。

```bash
curl -I --max-time 5 http://127.0.0.1:8096
sudo systemctl status jellyfin --no-pager
journalctl -u jellyfin -n 100 --no-pager
```

Jellyfin のデータ配置:

- 設定: `/mnt/data/jellyfin/config`
- キャッシュ: `/mnt/data/jellyfin/cache`
- ミュージックビデオ: `/mnt/data/jellyfin/music-videos`
- その他ライブラリ候補: `/mnt/data/jellyfin/movies`, `/mnt/data/jellyfin/tv`
- Compose: `/home/mediaserver/ManageMediaServer/docker/jellyfin/docker-compose.yml`

### アクセス範囲

家庭内 LAN は内部ネットワークとして扱い、家庭内の端末からはサーバーの LAN IP へ直接アクセスします。家庭外からは Tailscale のプライベートネットワーク経由でアクセスします。ルーターのポート開放、ポートフォワーディング、インターネットへの直接公開は行いません。

利用者向けの標準アクセス先:

```text
家庭内 LAN:
  Immich:  http://<LAN IP>:2283
  Jellyfin: http://<LAN IP>:8096

家庭外 + Tailscale 接続中:
  Immich:  http://100.69.11.74:2283
  Jellyfin: http://100.69.11.74:8096
```

確認コマンド:

```bash
command -v tailscale
tailscale status
tailscale ip -4
systemctl status tailscaled --no-pager
```

現在このサーバーは Tailscale に参加済みです。

```text
Tailscale IP: 100.69.11.74
Node name: home-ubuntu
tailscaled.service: enabled / active
```

再構築時など、未導入の場合は Ubuntu に Tailscale をインストールして認証します。

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

インストール後、Tailscale 管理画面でこの Ubuntu サーバーが tailnet に参加していることを確認します。

HTTPS が必要な場合は Tailscale Serve を使い、Tailscale ネットワーク内だけで HTTPS 化できます。標準アクセスは raw port ですが、Serve を使う場合は既存設定を確認してから設定します。

```bash
tailscale serve status
tailscale funnel status
sudo tailscale serve --bg --https=443 http://127.0.0.1:2283
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8096
tailscale serve status
```

この場合のアクセス例:

```text
Immich:  https://<MagicDNS name>
Jellyfin: https://<MagicDNS name>:8443
```

Funnel はインターネット公開用なので、通常運用では使いません。

### rclone 同期

rclone はクラウドストレージの内容を Immich 外部ライブラリへ取り込みます。同期方針と削除操作の安全条件は [docs/同期設計.md](docs/同期設計.md) を参照します。

```bash
systemctl status rclone-media-sync.timer --no-pager
systemctl status rclone-media-sync.service --no-pager
systemctl list-timers rclone-media-sync.timer --no-pager
sudo tail -100 /mnt/data/config/rclone/logs/media-sync.log
```

手動のメディア同期が必要な場合:

```bash
./scripts/ops/rclone-media-sync.sh
```

削除なしで取り込みとバックアップだけを実行する場合:

```bash
./scripts/ops/rclone-media-sync.sh --no-delete
```

### メディアバックアップ

`media-backup.timer` は、アプリケーションの完全復元ではなく、写真・動画ファイルそのものを物理的に別のドライブへ守るための仕組みです。

対象:

| 元 | 先 | 内容 |
| --- | --- | --- |
| `/mnt/data/immich/upload` | `/mnt/backup/immich-upload` | Immich に直接アップロードされた写真・動画 |
| `/mnt/data/immich/external` | `/mnt/backup/immich-backup` | rclone で取り込んだ Immich 外部ライブラリ |
| `/mnt/data/jellyfin/music-videos` | `/mnt/backup/jellyfin-backup` | Jellyfin のミュージックビデオ |

方針:

- `rclone copy` で追加コピーする
- バックアップ先からの自動削除は行わない
- 世代管理、暗号化リポジトリ、PostgreSQL dump は行わない
- Immich/Jellyfin の設定、操作履歴、DB の完全復元は目的にしない
- 復旧時は、メディアファイルを Immich/Jellyfin または別アプリケーションへ再取り込みできることを重視する

手動確認:

```bash
./scripts/ops/media-backup.sh --dry-run
./scripts/ops/media-backup.sh
```

systemd timer の確認:

```bash
systemctl status media-backup.timer --no-pager
systemctl list-timers media-backup.timer --no-pager
journalctl -u media-backup.service -n 100 --no-pager
sudo tail -100 /mnt/data/config/media-backup/logs/media-backup.log
```

初回導入または本番反映時は、リポジトリの作業コピーから以下を実行します。

```bash
./scripts/ops/install-media-backup-systemd.sh
```

必要に応じて `/home/mediaserver/ManageMediaServer/config/env/media-backup.env` を編集し、バックアップ対象や空き容量閾値を変更します。

## 運用コマンド

### サービス操作

```bash
sudo systemctl status immich jellyfin rclone-media-sync.timer --no-pager
sudo systemctl restart immich
sudo systemctl restart jellyfin
sudo systemctl restart rclone-media-sync.service
sudo systemctl restart media-backup.service
sudo systemctl restart media-health-check.service
sudo systemctl stop immich jellyfin
sudo systemctl start immich jellyfin
```

残している簡易スクリプト:

```bash
./scripts/ops/start-services.sh
./scripts/ops/stop-services.sh
./scripts/ops/rclone-media-sync.sh
./scripts/ops/media-backup.sh
./scripts/ops/media-health-check.sh
```

### Docker Compose

```bash
cd /home/mediaserver/ManageMediaServer

docker compose -f docker/immich/docker-compose.yml ps
docker compose -f docker/jellyfin/docker-compose.yml ps

docker compose -f docker/immich/docker-compose.yml logs -n 100
docker compose -f docker/jellyfin/docker-compose.yml logs -n 100

docker compose -f docker/immich/docker-compose.yml pull
docker compose -f docker/jellyfin/docker-compose.yml pull
```

`ubuntu` ユーザーが Docker ソケットへアクセスできない場合は、`mediaserver` ユーザーまたは `sudo` で確認します。

Immich/Jellyfin は個人運用で手動のリリース監視を続けるのが難しいため、完全固定ではなく major 範囲を固定して日次更新する設計にします。

- Immich: `IMMICH_VERSION=v2`
- Jellyfin: `jellyfin/jellyfin:10`

`release` や `latest` は major をまたいだ意図しない更新を招くため使いません。major 更新が公開された場合は自動適用せず、Discord へ通知して手動判断します。

実運用の `docker/immich/.env` に `IMMICH_VERSION=release` が残っている場合、Compose の既定値より `.env` が優先されます。本番反映時は `IMMICH_VERSION=v2` へ変更します。

### ディスク確認

```bash
df -h / /mnt/data /mnt/backup
mountpoint /mnt/backup
du -sh /mnt/data/* /mnt/backup/* 2>/dev/null
```

現在、`/mnt/data` は専用マウントポイントではなく、ルートファイルシステム上のディレクトリです。物理デバイス構成の制約により、当面はこの構成を前提に運用します。

この制約下では、メディアデータの増加が OS 領域を直接圧迫します。長期運用では以下を必須の運用条件とします。

- `/` と `/mnt/data` の空き容量を定期確認する
- `/mnt/data` の利用量が増えた場合は、Jellyfin メディア、Immich 外部ライブラリ、バックアップ対象を優先的に整理する
- OS 更新、Docker pull、Immich/Jellyfin 更新の前に十分な空き容量を確認する
- 将来物理構成を変更できる場合は、`/mnt/data` を専用ディスクまたは専用 LVM 論理ボリュームへ移行する

`/mnt/backup` は `/dev/sda1` の ext4 マウントです。

### Tailscale 確認

```bash
tailscale status
tailscale ip -4
tailscale serve status
tailscale funnel status
systemctl status tailscaled --no-pager
```

Tailscale に未ログインの場合:

```bash
sudo tailscale up
```

ファイアウォールは、家庭内 LAN と Tailscale からの Immich/Jellyfin だけを許可します。`LAN_CIDR` は家庭内 LAN の実際の CIDR に置き換えます。UFW を有効化する前に SSH の許可状態を確認します。

Docker の published port は Docker が iptables ルールを追加するため、UFW だけでは制限できない場合があります。UFW はホスト側サービスの基本方針として使い、Docker published port の制限は `media-firewall.service` で `DOCKER-USER` chain に明示します。

```bash
LAN_CIDR=192.168.0.0/24

sudo ufw status verbose
sudo ufw allow OpenSSH
sudo ufw allow from "$LAN_CIDR" to any port 2283 proto tcp
sudo ufw allow from "$LAN_CIDR" to any port 8096 proto tcp
sudo ufw allow in on tailscale0 to any port 2283 proto tcp
sudo ufw allow in on tailscale0 to any port 8096 proto tcp
sudo ufw status numbered

./scripts/ops/deploy-managed-files.sh
sudo test -f /home/mediaserver/ManageMediaServer/config/env/media-firewall.env || sudo install -m 0640 -o mediaserver -g mediaserver config/env/media-firewall.env.example /home/mediaserver/ManageMediaServer/config/env/media-firewall.env
sudoedit /home/mediaserver/ManageMediaServer/config/env/media-firewall.env
sudo systemctl enable --now media-firewall.service
sudo systemctl restart jellyfin
sudo systemctl status media-firewall.service --no-pager
sudo iptables -S DOCKER-USER
```

Jellyfin DLNA を使う場合だけ、家庭内 LAN から `1900/udp` を許可します。DLNA を使わない場合は、Jellyfin 管理画面でも無効化します。`DOCKER-USER` の制限は `media-firewall.service` で再起動後も再適用します。

反映後は、サーバー上と別端末から到達性を確認します。

```bash
ss -ltnup | grep -E ':(2283|8096|8920)\b' || true
ss -lunp | grep ':1900\b' || true
sudo ufw status numbered
sudo iptables -S DOCKER-USER

# 家庭内 LAN の端末から
curl -I --max-time 5 http://<LAN IP>:2283
curl -I --max-time 5 http://<LAN IP>:8096

# Tailscale 接続中の端末から
curl -I --max-time 5 http://<Tailscale IP>:2283
curl -I --max-time 5 http://<Tailscale IP>:8096
```

家庭内 LAN でも Tailscale でもない到達元からは、Immich/Jellyfin に接続できないことを確認します。

## 環境概要

| 項目 | 値 |
| --- | --- |
| OS | Ubuntu 24.04 LTS |
| ホスト名 | `home-ubuntu` |
| 運用ユーザー | `mediaserver` |
| 作業ユーザー | `ubuntu` |
| Git checkout | `/home/ubuntu/repos/ManageMediaServer` |
| 本番配置コピー | `/home/mediaserver/ManageMediaServer` |
| データ領域 | `/mnt/data` |
| バックアップ領域 | `/mnt/backup` |
| 家庭内 LAN CIDR | `192.168.0.0/24` |
| Tailscale IP | `100.69.11.74` |
| Tailscale node | `home-ubuntu` |
| システムタイムゾーン | `Etc/UTC` |
| rclone timer timezone | `Asia/Tokyo` |

### Git checkout と本番配置コピーの役割

`/home/ubuntu/repos/ManageMediaServer` は Git 管理される作業コピーで、変更元です。README、Compose、systemd unit、運用スクリプト、設定テンプレートはここで編集し、commit/push します。

`/home/mediaserver/ManageMediaServer` は systemd や Docker Compose が参照する本番配置コピーです。本番配置コピーを直接編集して正とせず、作業コピーから管理対象ファイルだけを反映します。

本番反映は作業コピーで実行します。

```bash
cd /home/ubuntu/repos/ManageMediaServer
./scripts/ops/deploy-managed-files.sh --dry-run
./scripts/ops/deploy-managed-files.sh
```

`deploy-managed-files.sh` は以下を行います。

- Git 管理対象の README、docs、Compose、systemd unit/timer、運用スクリプト、設定テンプレートを `/home/mediaserver/ManageMediaServer` へ反映する
- systemd unit/timer を `/etc/systemd/system` へ反映し、`systemctl daemon-reload` を実行する
- 上書き前のファイルを `/home/mediaserver/ManageMediaServer/.deploy-backups/` にバックアップする
- `.env`、`config/env/*.env`、`config/rclone/rclone.conf`、ログ、`/mnt/data`、`/mnt/backup` はコピーも上書きもしない

主要ポート:

| ポート | サービス |
| --- | --- |
| `2283/tcp` | Immich。家庭内 LAN と Tailscale からのみ許可。Docker published port は `DOCKER-USER` でも制限 |
| `8096/tcp` | Jellyfin。家庭内 LAN と Tailscale からのみ許可。Docker published port は `DOCKER-USER` でも制限 |
| `8920/tcp` | Jellyfin HTTPS。標準構成では使わない |
| `1900/udp` | Jellyfin DLNA。使う場合だけ家庭内 LAN から許可 |
| `22/tcp` | SSH |

## リポジトリ構成

```text
README.md
LICENSE
docs/
  同期設計.md
systemd/
  media-firewall.service
  media-backup.service
  media-backup.timer
  media-app-update.service
  media-app-update.timer
  media-health-check.service
  media-health-check.timer
  rclone-media-sync.service
  rclone-media-sync.timer
docker/
  immich/
    docker-compose.yml
    .env.example
  jellyfin/
    docker-compose.yml
scripts/
  ops/
    apply-media-firewall.sh
    deploy-managed-files.sh
    install-media-app-update-systemd.sh
    install-media-backup-systemd.sh
    install-media-health-check-systemd.sh
    media-app-update.sh
    media-backup.sh
    media-health-check.sh
    rclone-media-sync.sh
    start-services.sh
    stop-services.sh
config/
  env/
    media-firewall.env.example
    media-backup.env.example
    media-app-update.env.example
    media-health-check.env.example
    notification.env.example
  rclone/
    rclone.conf.example
    media-sync-excludes.txt
```

実行時に使うが Git 管理しないもの:

- `docker/immich/.env`
- `docker/*/.env`
- `config/env/notification.env`
- `config/env/media-app-update.env`
- `config/env/media-health-check.env`
- `config/rclone/rclone.conf`
- `/mnt/data/config/rclone/rclone.conf`
- ログ
- 実データ
- バックアップデータ
- 本番配置コピーの `.deploy-backups/`

## 設計方針

### 本番配置は deploy-managed-files.sh で反映する

Git checkout は `/home/ubuntu/repos/ManageMediaServer`、本番配置コピーは `/home/mediaserver/ManageMediaServer` として分けます。systemd unit は本番配置コピー内の Compose とスクリプトを参照します。

管理ファイルを更新したら、作業コピーから `scripts/ops/deploy-managed-files.sh` を実行して本番配置コピーへ反映します。反映対象は明示リストで管理し、実値入りの env、`rclone.conf`、ログ、実データ、バックアップデータは対象外です。

このスクリプトは systemd unit/timer も `/etc/systemd/system` へ反映しますが、timer の enable/disable やサービス起動状態の変更は行いません。初回導入や有効化は各 install script または個別の運用手順で行います。

### Docker Compose は Git 管理する

Immich と Jellyfin の Compose はリポジトリで管理します。

- Immich: `docker/immich/docker-compose.yml`
- Jellyfin: `docker/jellyfin/docker-compose.yml`

`.env` はホスト固有値と秘匿情報を含むため Git 管理しません。Immich は `docker/immich/.env.example` をテンプレートとして管理します。

### systemd で Compose を管理する

Immich と Jellyfin は Docker Compose を systemd oneshot service から起動します。

`immich.service`:

```ini
WorkingDirectory=/home/mediaserver/ManageMediaServer
ExecStart=/usr/bin/docker compose -f /home/mediaserver/ManageMediaServer/docker/immich/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f /home/mediaserver/ManageMediaServer/docker/immich/docker-compose.yml down
```

`jellyfin.service`:

```ini
WorkingDirectory=/home/mediaserver/ManageMediaServer
ExecStart=/usr/bin/docker compose -f /home/mediaserver/ManageMediaServer/docker/jellyfin/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f /home/mediaserver/ManageMediaServer/docker/jellyfin/docker-compose.yml down
```

### 外部アクセスは Tailscale に統一する

家庭内 LAN は内部ネットワークとして扱い、家庭外からのアクセスは Tailscale のプライベートネットワークを使います。

- ルーターのポート開放は行わない
- Immich/Jellyfin をインターネットへ直接公開しない
- UFW と Docker の `DOCKER-USER` chain で家庭内 LAN と Tailscale 以外からの Immich/Jellyfin への到達を許可しない
- Tailscale の WireGuard ベース暗号化を前提にする
- 家族共有が必要になった場合は Tailscale のユーザー・デバイス管理で許可する
- HTTPS が必要な場合は Tailscale Serve を使う

通常のアクセスは、家庭内では LAN IP、家庭外では `100.x.x.x:2283` / `100.x.x.x:8096` または MagicDNS 名を使います。

### rclone の同期設計は docs に分ける

rclone の同期方針、画像と動画の扱い、削除操作の安全条件は [docs/同期設計.md](docs/同期設計.md) にまとめます。

`rclone-media-sync.timer` は daily AM 8:00 JST に実行します。サーバー全体の timezone は変更せず、timer 側で `Asia/Tokyo` を指定します。

```ini
OnCalendar=*-*-* 08:00:00 Asia/Tokyo
```

旧 `rclone-sync.timer` は `rclone sync` による削除反映リスクがあるため、通常運用では使いません。

### rclone-media-sync の配置

本番で `rclone-media-sync.service` が呼ぶ正のスクリプトは `/home/mediaserver/ManageMediaServer/scripts/ops/rclone-media-sync.sh` です。`/home/mediaserver/ManageMediaServer` は Git checkout ではなく、本番配置コピーとして扱います。変更後は Git checkout から本番配置へ `deploy-managed-files.sh` で反映します。

```bash
test -x /home/mediaserver/ManageMediaServer/scripts/ops/rclone-media-sync.sh
test -f /home/mediaserver/ManageMediaServer/config/rclone/media-sync-excludes.txt
```

systemd unit/timer を配置します。

```bash
./scripts/ops/deploy-managed-files.sh
sudo systemctl enable --now rclone-media-sync.timer
systemctl list-timers 'rclone*' --no-pager
```

旧 timer を停止します。

```bash
sudo systemctl stop rclone-sync.timer
sudo systemctl disable rclone-sync.timer
systemctl is-enabled rclone-sync.timer
systemctl is-active rclone-sync.timer
systemctl list-timers 'rclone*' --no-pager
```

期待状態:

- `rclone-sync.timer` は disabled / inactive
- `rclone-sync.timer` は次回実行対象に出ない
- `rclone-media-sync.timer` だけが JST AM 8:00 の次回実行として出る

問題が出た場合は、まず削除なしの手動実行へ退避します。

```bash
sudo systemctl stop rclone-media-sync.timer
sudo systemctl disable rclone-media-sync.timer
./scripts/ops/rclone-media-sync.sh --no-delete
```

旧 `rclone-sync.timer` の再有効化は `rclone sync` の削除反映リスクがあるため、最終手段として扱います。

### media-backup の配置

`media-backup.timer` は daily AM 4:00 JST に実行します。`rclone-media-sync.timer` より前に動かし、前回までに取り込まれているメディアを `/mnt/backup` へ追加コピーします。

```ini
OnCalendar=*-*-* 04:00:00 Asia/Tokyo
```

本番で `media-backup.service` が呼ぶ正のスクリプトは `/home/mediaserver/ManageMediaServer/scripts/ops/media-backup.sh` です。管理ファイルの反映には `deploy-managed-files.sh` を使います。初回導入や timer の有効化は `install-media-backup-systemd.sh` を使います。

```bash
./scripts/ops/deploy-managed-files.sh
./scripts/ops/install-media-backup-systemd.sh
```

配置後の期待状態:

- `media-backup.timer` が enabled / active
- `/mnt/backup` が mountpoint
- `/mnt/backup/immich-upload`
- `/mnt/backup/immich-backup`
- `/mnt/backup/jellyfin-backup`
- `/mnt/data/config/media-backup/logs/media-backup.log`

このバックアップはメディアファイルの退避専用です。Immich PostgreSQL、Jellyfin 設定、サムネイル、キャッシュ、ユーザー操作履歴の完全復元は対象外です。アプリケーション移行時は、バックアップ先のメディアファイルを新しいアプリケーションへ再取り込みします。

### アプリ更新バッチの設計

Immich/Jellyfin のセキュリティアップデートを人手で追い続ける運用は現実的ではないため、アプリ更新は日次バッチで処理します。ただし major 更新は破壊的変更を含む可能性があるため、自動適用せず通知だけ行います。

systemd unit:

| unit | 時刻 | 役割 |
| --- | --- | --- |
| `media-backup.timer` | daily AM 4:00 JST | メディアファイルを `/mnt/backup` へ追加コピー |
| `media-app-update.timer` | daily AM 5:00 JST | バックアップ後に Immich/Jellyfin を同一 major 内で更新 |
| `media-health-check.timer` | every 10 minutes | Immich/Jellyfin、rclone timer、ディスク空き容量を監視 |
| `rclone-media-sync.timer` | daily AM 8:00 JST | クラウドストレージから新規メディアを取り込み |

`media-app-update.service` は `/home/mediaserver/ManageMediaServer/scripts/ops/media-app-update.sh` を呼びます。処理順序は以下です。

1. `/mnt/backup` が mountpoint であることを確認する
2. `media-backup.service` の直近実行が成功していることを確認する
3. `/`, `/mnt/data`, `/mnt/backup` の空き容量を確認する
4. GitHub Releases から Immich/Jellyfin の最新 major を確認する
5. 現在の固定 major より新しい major があれば、更新せず Discord へ通知する
6. major が同じ範囲の更新だけ `docker compose pull && docker compose up -d` で適用する
7. `docker compose ps` と HTTP 疎通で Immich/Jellyfin の起動状態を確認する
8. 成功、更新なし、失敗、major 更新検知を Discord へ通知する

自動更新対象:

| サービス | 自動更新タグ | 自動適用範囲 | major 更新時 |
| --- | --- | --- | --- |
| Immich | `IMMICH_VERSION=v2` | `v2.x.x` | 通知のみ |
| Jellyfin | `jellyfin/jellyfin:10` | `10.x.x` | 通知のみ |

現行の `media-backup.timer` は写真・動画ファイルの保全が目的であり、Immich PostgreSQL、Jellyfin 設定、サムネイル、キャッシュの完全復元は保証しません。そのため、日次自動更新は「メディアファイルを失わないこと」を最優先にし、アプリの完全ロールバックは前提にしません。Immich は downgrade が安全とは限らないため、更新失敗時は旧タグへ戻すよりも、ログ確認、必要に応じた公式手順での forward fix、最終的にはメディア再取り込みを復旧方針とします。

手動確認:

```bash
./scripts/ops/media-app-update.sh --check-only
./scripts/ops/media-app-update.sh --dry-run
```

systemd timer の導入:

```bash
./scripts/ops/deploy-managed-files.sh
./scripts/ops/install-media-app-update-systemd.sh
```

systemd timer の確認:

```bash
systemctl status media-app-update.timer --no-pager
systemctl list-timers media-app-update.timer --no-pager
journalctl -u media-app-update.service -n 100 --no-pager
sudo tail -100 /mnt/data/config/media-app-update/logs/media-app-update.log
```

停止する場合:

```bash
sudo systemctl disable --now media-app-update.timer
```

### ヘルス監視

`media-health-check.timer` は 10 分ごとに以下を確認します。

- Immich/Jellyfin の HTTP 応答
- Immich/Jellyfin の Docker Compose サービスが running であること
- `rclone-media-sync.timer` が active/enabled であること
- `/`, `/mnt/data`, `/mnt/backup` の空き容量
- `/mnt/backup` が mountpoint であること

閾値や URL は `/home/mediaserver/ManageMediaServer/config/env/media-health-check.env` で変更できます。既定の空き容量閾値は各 1 GiB です。失敗時は `notification.env` の Discord 設定を使って通知します。通常時の成功通知は `NOTIFY_ON_SUCCESS=false` で抑制します。

systemd timer の導入:

```bash
./scripts/ops/deploy-managed-files.sh
./scripts/ops/install-media-health-check-systemd.sh
```

手動確認:

```bash
./scripts/ops/media-health-check.sh --no-notify
systemctl status media-health-check.timer --no-pager
systemctl list-timers media-health-check.timer --no-pager
journalctl -u media-health-check.service -n 100 --no-pager
sudo tail -100 /mnt/data/config/media-health-check/logs/media-health-check.log
```

停止する場合:

```bash
sudo systemctl disable --now media-health-check.timer
```

### Discord 通知

通知設定はテンプレートから作成します。

```bash
cp config/env/notification.env.example config/env/notification.env
```

`config/env/notification.env` に本番の Webhook URL を設定し、通知を有効化します。

```env
NOTIFICATION_ENABLED=true
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
```

実値入り `notification.env` は Git 管理しません。過去コミットに Webhook URL が含まれていたため、本番 Webhook URL はローテーション済みのものを使います。

### データとバックアップを分ける

運用データ:

```text
/mnt/data/
  immich/
    external/
    upload/
    postgres/
  jellyfin/
    config/
    cache/
    music-videos/
    movies/
    tv/
  config/
    rclone/
      rclone.conf
      logs/
    media-backup/
      logs/
  temp/
```

バックアップ:

```text
/mnt/backup/
  immich-upload/
  immich-backup/
  jellyfin-backup/
  media/
  config/
```

`/mnt/backup` は物理的に別ディスクへ分離します。メディアバックアップは現在状態のミラーではなく、復旧用の追加コピー先として扱います。`/mnt/data` 側でファイルを削除しても、バックアップ先から自動削除しません。

`/mnt/data` も同様に専用マウント化するのが望ましいです。

## 実際の設定

### Immich Compose

主要設定:

- image: `ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-v2}`
- ML image: `ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-v2}`
- Redis: `docker.io/valkey/valkey:8-bookworm`
- PostgreSQL: `ghcr.io/immich-app/postgres:14-vectorchord0.3.0-pgvectors0.2.0`
- port: `2283:2283`
- firewall: 家庭内 LAN と `tailscale0` からのみ `2283/tcp` を許可。Docker published port は `DOCKER-USER` でも制限
- upload mount: `${UPLOAD_LOCATION}:/usr/src/app/upload`
- external mount: `${EXTERNAL_PATH:-/tmp/empty}:/usr/src/app/external:ro`
- db mount: `${DB_DATA_LOCATION}:/var/lib/postgresql/data`

`.env.example`:

```env
UPLOAD_LOCATION=/mnt/data/immich/upload
DB_DATA_LOCATION=/mnt/data/immich/postgres
EXTERNAL_PATH=/mnt/data/immich/external
IMMICH_VERSION=v2
DB_PASSWORD=change-me
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
```

### Jellyfin Compose

主要設定:

- image: `jellyfin/jellyfin:10`
- user: `1001:1001`
- timezone: `Asia/Tokyo`
- config: `${DATA_ROOT:-/mnt/data}/jellyfin/config:/config`
- cache: `${DATA_ROOT:-/mnt/data}/jellyfin/cache:/cache`
- media: `${DATA_ROOT:-/mnt/data}/jellyfin/music-videos:/media/music-videos:ro`
- ports: `8096`
- firewall: 家庭内 LAN と `tailscale0` からのみ `8096/tcp` を許可。Docker published port は `DOCKER-USER` でも制限
- `8920/tcp`: 標準構成では使わない
- `1900/udp`: DLNA を使う場合だけ家庭内 LAN から許可

## 同期・バックアップ設計

同期設計の詳細は [docs/同期設計.md](docs/同期設計.md) を参照します。

## トラブルシューティング

### Immich が見えない

```bash
curl -I --max-time 5 http://127.0.0.1:2283
sudo systemctl status immich --no-pager
journalctl -u immich -n 100 --no-pager
docker compose -f /home/mediaserver/ManageMediaServer/docker/immich/docker-compose.yml ps
docker compose -f /home/mediaserver/ManageMediaServer/docker/immich/docker-compose.yml logs -n 100
sudo ufw status numbered
```

### Jellyfin が見えない

```bash
curl -I --max-time 5 http://127.0.0.1:8096
sudo systemctl status jellyfin --no-pager
journalctl -u jellyfin -n 100 --no-pager
docker compose -f /home/mediaserver/ManageMediaServer/docker/jellyfin/docker-compose.yml ps
docker compose -f /home/mediaserver/ManageMediaServer/docker/jellyfin/docker-compose.yml logs -n 100
sudo ufw status numbered
```

### rclone が失敗する

```bash
systemctl status rclone-media-sync.service --no-pager
sudo tail -100 /mnt/data/config/rclone/logs/media-sync.log
```

Personal Vault 関連のエラーが出る場合は、[docs/同期設計.md](docs/同期設計.md) の除外方針を確認します。

反映後は reload して再実行します。

```bash
sudo systemctl daemon-reload
sudo systemctl restart rclone-media-sync.service
sudo systemctl status rclone-media-sync.service --no-pager
```

### メディアバックアップが失敗する

```bash
systemctl status media-backup.timer --no-pager
systemctl status media-backup.service --no-pager
systemctl list-timers media-backup.timer --no-pager
sudo tail -100 /mnt/data/config/media-backup/logs/media-backup.log
```

dry-run でコピー対象を確認します。

```bash
./scripts/ops/media-backup.sh --dry-run
```

`/mnt/backup` がマウントされていない、または空き容量が閾値未満の場合は hard fail します。`media-backup.env` の既定閾値は 1 GiB です。

### Docker 権限エラー

```bash
id ubuntu
id mediaserver
ls -l /var/run/docker.sock
```

`ubuntu` ユーザーが Docker グループに入っていない場合、`sudo docker ...` または `mediaserver` ユーザーで確認します。

### `/mnt/data` 容量不足

```bash
df -h / /mnt/data
du -sh /mnt/data/* 2>/dev/null
```

`/mnt/data` は専用マウント化を推奨します。移行時はサービス停止、バックアップ、rsync、fstab 更新、再起動確認の順で進めます。

`rclone-media-sync.sh` は事前確認で `/mnt/data/immich/external` と `/mnt/backup` の空き容量を確認し、既定でそれぞれ 1 GiB 未満なら削除フェーズへ進まず終了します。閾値は `DATA_MIN_FREE_KIB` と `BACKUP_MIN_FREE_KIB` で変更できます。

### `/mnt/backup` がマウントされていない

```bash
mountpoint /mnt/backup
df -h /mnt/backup
sudo mount /mnt/backup
```

`/etc/fstab` の `/mnt/backup` エントリを確認します。

## Git 管理方針

管理するもの:

- `README.md`
- `AGENTS.md`
- `docker/immich/docker-compose.yml`
- `docker/immich/.env.example`
- `docker/jellyfin/docker-compose.yml`
- `config/env/*.env.example`
- `scripts/ops/*.sh`
- `systemd/*.service`
- `systemd/*.timer`
- 設定テンプレート
- 本番配置へ反映する管理ファイルの一覧は `scripts/ops/deploy-managed-files.sh`

管理しないもの:

- 実データ
- バックアップ
- ログ
- `.env`
- `rclone.conf`
- `notification.env`
- `media-firewall.env`
- `media-backup.env`
- `media-app-update.env`
- 認証情報
- `/home/mediaserver/ManageMediaServer/.deploy-backups/`

## ライセンス

MIT License
