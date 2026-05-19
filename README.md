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
| Immich | `http://localhost:2283` | 写真・短尺動画の管理、外部ライブラリ参照 |
| Jellyfin | `http://localhost:8096` | 長尺動画・ミュージックビデオの視聴 |
| rclone | `rclone-sync.timer` | クラウドストレージから `/mnt/data/immich/external` へ同期 |
| Tailscale | `100.x.x.x` または MagicDNS 名 | ポート開放なしの外部アクセス |
| Discord 通知 | 設定ファイル: `config/env/notification.env` | 監視・バックアップ結果通知 |

## 日常的な利用方法

### Immich

Immich は写真・短尺動画の管理に使います。

```bash
curl -I --max-time 5 http://localhost:2283
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
curl -I --max-time 5 http://localhost:8096
sudo systemctl status jellyfin --no-pager
journalctl -u jellyfin -n 100 --no-pager
```

Jellyfin のデータ配置:

- 設定: `/mnt/data/jellyfin/config`
- キャッシュ: `/mnt/data/jellyfin/cache`
- ミュージックビデオ: `/mnt/data/jellyfin/music-videos`
- その他ライブラリ候補: `/mnt/data/jellyfin/movies`, `/mnt/data/jellyfin/tv`
- Compose: `/home/mediaserver/ManageMediaServer/docker/jellyfin/docker-compose.yml`

### Tailscale 経由の外部アクセス

外出先からは Tailscale のプライベートネットワーク経由でアクセスします。ルーターのポート開放、ポートフォワーディング、インターネットへの直接公開は行いません。

Tailscale 接続中の端末から以下でアクセスします。

```text
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

Tailscale Serve を使う場合は、Tailscale ネットワーク内だけで HTTPS 化できます。例:

```bash
sudo tailscale serve --bg --https=443 http://localhost:2283
sudo tailscale serve --bg --https=8443 http://localhost:8096
tailscale serve status
```

この場合のアクセス例:

```text
Immich:  https://<MagicDNS name>
Jellyfin: https://<MagicDNS name>:8443
```

Serve 設定を変更する場合は、既存設定を確認してから上書きします。

### rclone 同期

rclone はクラウドストレージの内容を Immich 外部ライブラリへ同期します。

```bash
systemctl status rclone-sync.timer --no-pager
systemctl status rclone-sync.service --no-pager
systemctl list-timers rclone-sync.timer --no-pager
sudo tail -100 /mnt/data/config/rclone/logs/sync.log
```

定期同期:

- systemd timer: `rclone-sync.timer`
- 実行間隔: hourly
- service: `rclone-sync.service`
- rclone config: `/mnt/data/config/rclone/rclone.conf`
- 同期元: `cloudstorageremote:/`
- 同期先: `/mnt/data/immich/external`
- ログ: `/mnt/data/config/rclone/logs/sync.log`

OneDrive の Personal Vault は rclone から列挙できず同期失敗の原因になるため、以下を除外しています。

```bash
--exclude "/個人用 Vault/**" --exclude "/Personal Vault/**"
```

手動のメディア同期が必要な場合:

```bash
./scripts/ops/rclone-media-sync.sh
```

このスクリプトは画像を同期し、動画をローカルへコピーしたうえでバックアップし、クラウド側から削除する運用を想定しています。実行前に対象と除外条件を確認してください。

## 運用コマンド

### サービス操作

```bash
sudo systemctl status immich jellyfin rclone-sync.timer --no-pager
sudo systemctl restart immich
sudo systemctl restart jellyfin
sudo systemctl restart rclone-sync.service
sudo systemctl stop immich jellyfin
sudo systemctl start immich jellyfin
```

残している簡易スクリプト:

```bash
./scripts/ops/start-services.sh
./scripts/ops/stop-services.sh
./scripts/ops/rclone-media-sync.sh
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

### ディスク確認

```bash
df -h / /mnt/data /mnt/backup
mountpoint /mnt/data
mountpoint /mnt/backup
du -sh /mnt/data/* /mnt/backup/* 2>/dev/null
```

現在、`/mnt/data` は専用マウントポイントではなく、ルートファイルシステム上のディレクトリです。メディア増加で OS 領域を圧迫しないよう、専用ディスクまたは専用 LVM 論理ボリュームとしてのマウントを推奨します。

`/mnt/backup` は `/dev/sda1` の ext4 マウントです。

### Tailscale 確認

```bash
tailscale status
tailscale ip -4
tailscale serve status
systemctl status tailscaled --no-pager
```

Tailscale に未ログインの場合:

```bash
sudo tailscale up
```

ファイアウォールを調整する場合は、Tailscale のアドレス範囲から Immich/Jellyfin へのアクセスを許可します。

```bash
sudo ufw allow in on tailscale0 to any port 2283 proto tcp
sudo ufw allow in on tailscale0 to any port 8096 proto tcp
```

## 環境概要

| 項目 | 値 |
| --- | --- |
| OS | Ubuntu 24.04 LTS |
| ホスト名 | `home-ubuntu` |
| 運用ユーザー | `mediaserver` |
| 作業ユーザー | `ubuntu` |
| 本番配置 | `/home/mediaserver/ManageMediaServer` |
| データ領域 | `/mnt/data` |
| バックアップ領域 | `/mnt/backup` |
| Tailscale IP | `100.69.11.74` |
| Tailscale node | `home-ubuntu` |
| タイムゾーン | `Asia/Tokyo` |

主要ポート:

| ポート | サービス |
| --- | --- |
| `2283/tcp` | Immich |
| `8096/tcp` | Jellyfin |
| `8920/tcp` | Jellyfin HTTPS |
| `1900/udp` | Jellyfin DLNA |
| `22/tcp` | SSH |

## リポジトリ構成

```text
README.md
LICENSE
docker/
  immich/
    docker-compose.yml
    .env.example
  jellyfin/
    docker-compose.yml
scripts/
  ops/
    rclone-media-sync.sh
    start-services.sh
    stop-services.sh
config/
  rclone/
    rclone.conf.example
```

実行時に使うが Git 管理しないもの:

- `docker/immich/.env`
- `docker/*/.env`
- `config/env/notification.env`
- `config/rclone/rclone.conf`
- `/mnt/data/config/rclone/rclone.conf`
- ログ
- 実データ
- バックアップデータ

## 設計方針

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

外部アクセスは Tailscale のプライベートネットワークを使います。

- ルーターのポート開放は行わない
- Immich/Jellyfin をインターネットへ直接公開しない
- Tailscale の WireGuard ベース暗号化を前提にする
- 家族共有が必要になった場合は Tailscale のユーザー・デバイス管理で許可する
- HTTPS が必要な場合は Tailscale Serve を使う

通常のアクセスは `100.x.x.x:2283` / `100.x.x.x:8096` または MagicDNS 名を使います。

### rclone はクラウド全体を同期し、Personal Vault を除外する

`rclone-sync.service`:

```ini
Environment=RCLONE_CONFIG=/mnt/data/config/rclone/rclone.conf
ExecStart=/usr/bin/rclone sync cloudstorageremote:/ /mnt/data/immich/external --exclude "/個人用 Vault/**" --exclude "/Personal Vault/**" --log-file=/mnt/data/config/rclone/logs/sync.log --log-level INFO
```

Personal Vault を除外しない場合、以下のようなエラーで同期全体が失敗します。

```text
invalidRequest: invalidResourceId: ObjectHandle is Invalid
```

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
  temp/
```

バックアップ:

```text
/mnt/backup/
  immich-backup/
  jellyfin-backup/
  system-backup/
  media/
  config/
```

`/mnt/backup` は物理的に別ディスクへ分離します。`/mnt/data` も同様に専用マウント化するのが望ましいです。

## 実際の設定

### Immich Compose

主要設定:

- image: `ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}`
- ML image: `ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}`
- Redis: `docker.io/valkey/valkey:8-bookworm`
- PostgreSQL: `ghcr.io/immich-app/postgres:14-vectorchord0.3.0-pgvectors0.2.0`
- port: `2283:2283`
- upload mount: `${UPLOAD_LOCATION}:/usr/src/app/upload`
- external mount: `${EXTERNAL_PATH:-/tmp/empty}:/usr/src/app/external:ro`
- db mount: `${DB_DATA_LOCATION}:/var/lib/postgresql/data`

`.env.example`:

```env
UPLOAD_LOCATION=/mnt/data/immich/upload
DB_DATA_LOCATION=/mnt/data/immich/postgres
EXTERNAL_PATH=/mnt/data/immich/external
IMMICH_VERSION=release
DB_PASSWORD=change-me
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
```

### Jellyfin Compose

主要設定:

- image: `jellyfin/jellyfin:latest`
- user: `1001:1001`
- timezone: `Asia/Tokyo`
- config: `${DATA_ROOT:-/mnt/data}/jellyfin/config:/config`
- cache: `${DATA_ROOT:-/mnt/data}/jellyfin/cache:/cache`
- media: `${DATA_ROOT:-/mnt/data}/jellyfin/music-videos:/media/music-videos:ro`
- ports: `8096`, `8920`, `1900/udp`

## 同期・バックアップ設計

基本フロー:

```text
クラウドストレージ
  -> rclone
  -> /mnt/data/immich/external
  -> Immich 外部ライブラリ
```

バックアップ:

```text
/mnt/data
  -> /mnt/backup
```

運用上の注意:

- rclone の定期同期は hourly
- Personal Vault は同期対象から除外する
- Immich 外部ライブラリは read-only として扱う
- Jellyfin のメディアも原則 read-only mount とする
- `.env` と `rclone.conf` は Git 管理しない

## トラブルシューティング

### Immich が見えない

```bash
curl -I --max-time 5 http://localhost:2283
sudo systemctl status immich --no-pager
journalctl -u immich -n 100 --no-pager
docker compose -f /home/mediaserver/ManageMediaServer/docker/immich/docker-compose.yml ps
docker compose -f /home/mediaserver/ManageMediaServer/docker/immich/docker-compose.yml logs -n 100
```

### Jellyfin が見えない

```bash
curl -I --max-time 5 http://localhost:8096
sudo systemctl status jellyfin --no-pager
journalctl -u jellyfin -n 100 --no-pager
docker compose -f /home/mediaserver/ManageMediaServer/docker/jellyfin/docker-compose.yml ps
docker compose -f /home/mediaserver/ManageMediaServer/docker/jellyfin/docker-compose.yml logs -n 100
```

### rclone が失敗する

```bash
systemctl status rclone-sync.service --no-pager
sudo tail -100 /mnt/data/config/rclone/logs/sync.log
```

Personal Vault 関連のエラーが出る場合、`rclone-sync.service` の `ExecStart` に以下が含まれているか確認します。

```bash
--exclude "/個人用 Vault/**" --exclude "/Personal Vault/**"
```

反映後は reload して再実行します。

```bash
sudo systemctl daemon-reload
sudo systemctl restart rclone-sync.service
sudo systemctl status rclone-sync.service --no-pager
```

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
- `docker/immich/docker-compose.yml`
- `docker/immich/.env.example`
- `docker/jellyfin/docker-compose.yml`
- `scripts/ops/*.sh`
- 設定テンプレート

管理しないもの:

- 実データ
- バックアップ
- ログ
- `.env`
- `rclone.conf`
- `notification.env`
- 認証情報

## ライセンス

MIT License
