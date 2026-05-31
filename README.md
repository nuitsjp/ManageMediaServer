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
| 日次メンテナンス | `media-daily-maintenance.timer` | バックアップ、アプリ更新、rclone 同期、OS 更新、必要時の再起動を直列実行 |
| rclone | `rclone-media-sync.service` | クラウドストレージから `/mnt/data/immich/external` へ取り込み |
| メディアバックアップ | `media-backup.service` | 写真・動画を物理別ドライブの `/mnt/backup` へ追加コピー |
| アプリ更新 | `media-app-update.service` | Immich/Jellyfin を同一 major 内で更新し、major 更新は検知だけ行う |
| Tailscale | `100.x.x.x` または MagicDNS 名 | 家庭外からのアクセス経路 |
| Discord 通知 | 設定ファイル: `config/env/notification.env` | 日次メンテナンス結果を 1 日 1 本に集約して通知 |

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

PostgreSQL データディレクトリは、ホスト上ではコンテナ内 PostgreSQL の UID/GID に由来する所有者として見える場合があります。復旧時や手動確認時に所有者が `ubuntu` や `mediaserver` でなくても、異常とは限りません。

復旧時は、原因が明確でないまま `/mnt/data/immich/postgres` に対して `chown -R`、`chmod -R`、所有者の一括変更を行わないでください。PostgreSQL が期待する所有者や権限を崩すと、DB が起動できなくなる可能性があります。

所有者と権限を確認する場合:

```bash
sudo find /mnt/data/immich/postgres -maxdepth 1 -printf '%M %u:%g %p\n'
sudo find /mnt/data/immich/postgres -mindepth 1 -maxdepth 1 -printf '%M %u:%g %p\n' | head
findmnt /mnt/data
docker compose -f /home/mediaserver/ManageMediaServer/docker/immich/docker-compose.yml ps
```

復旧後に Immich が起動しない場合は、まず Compose の状態と PostgreSQL コンテナのログを確認します。権限変更で直す前に、現在の所有者、権限、エラーログを記録します。

```bash
docker compose -f /home/mediaserver/ManageMediaServer/docker/immich/docker-compose.yml logs -n 100 database
```

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

Windows サーバーから動画を投入する場合は、Linux 側の Jellyfin ライブラリディレクトリを Samba 共有として公開し、Windows 側から追加コピーします。

想定する共有:

| Windows からの共有名 | Linux 上の実体 | 用途 |
| --- | --- | --- |
| `\\home-ubuntu\jellyfin-music-videos` | `/mnt/data/jellyfin/music-videos` | ミュージックビデオ投入 |
| `\\home-ubuntu\jellyfin-movies` | `/mnt/data/jellyfin/movies` | 映画・長尺動画投入 |
| `\\home-ubuntu\jellyfin-tv` | `/mnt/data/jellyfin/tv` | TV 番組などのシリーズ投入 |

日常運用では、Windows 側から `robocopy` で追加コピーします。Jellyfin 側でライブラリスキャンを行えば、コピー後の動画を認識できます。

```powershell
robocopy D:\Videos \\home-ubuntu\jellyfin-music-videos /E /Z /R:2 /W:5
```

安全のため、通常運用では `/MIR` や `/PURGE` を使った削除同期は行いません。Windows 側の整理や誤削除が Linux 側の Jellyfin ライブラリへ波及しないよう、まずは追加コピーを標準にします。

Samba 共有は家庭内 LAN または Tailscale 経由でのみ利用します。ルーターのポート開放、ポートフォワーディング、インターネットへの直接公開は行いません。

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
MagicDNS name: home-ubuntu.tail1bf795.ts.net
tailscaled.service: enabled / active
```

再構築時など、未導入の場合は Ubuntu に Tailscale をインストールして認証します。

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

インストール後、Tailscale 管理画面でこの Ubuntu サーバーが tailnet に参加していることを確認します。

HTTPS が必要な場合は Tailscale Serve を使い、Tailscale ネットワーク内だけで HTTPS 化できます。標準アクセスは raw port ですが、Serve を使う場合は既存設定を確認してから設定します。

この構成では、証明書は Tailscale の MagicDNS と HTTPS Certificates に任せます。Immich/Jellyfin コンテナには証明書を配置せず、HTTPS 終端は `tailscaled` が担当します。Tailscale 管理画面で MagicDNS と HTTPS Certificates が有効であることが前提です。

```bash
tailscale serve status
tailscale funnel status
sudo tailscale serve --bg --https=443 http://127.0.0.1:2283
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8096
tailscale serve status
tailscale funnel status
```

この場合のアクセス例:

```text
Immich:  https://home-ubuntu.tail1bf795.ts.net/
Jellyfin: https://home-ubuntu.tail1bf795.ts.net:8443/
```

Funnel はインターネット公開用なので、通常運用では使いません。`tailscale funnel status` に同じ endpoint が表示されても、`(tailnet only)` と表示されている場合は Funnel によるインターネット公開ではありません。

HTTPS endpoint の確認:

```bash
curl -I --max-time 15 https://home-ubuntu.tail1bf795.ts.net/
curl -I --max-time 15 https://home-ubuntu.tail1bf795.ts.net:8443/
```

Immich は `/` に対して `404` を返す場合がありますが、HTTPS で応答が返っていれば Tailscale Serve から Immich への到達確認として扱えます。Jellyfin は `302` で `/web/` へリダイレクトします。

停止・ロールバック:

```bash
sudo tailscale serve --https=443 off
sudo tailscale serve --https=8443 off
tailscale serve status
tailscale funnel status
```

### rclone 同期

rclone はクラウドストレージの内容を Immich 外部ライブラリへ取り込みます。同期方針と削除操作の安全条件は [docs/同期設計.md](docs/同期設計.md) を参照します。

`rclone.conf` は認証情報を含むため Git 管理しません。リポジトリでは `config/rclone/rclone.conf.example` だけを管理し、実設定は `/mnt/data/config/rclone/rclone.conf` に配置します。

初期セットアップ:

```bash
sudo install -m 0700 -d /mnt/data/config/rclone
sudo install -m 0600 config/rclone/rclone.conf.example /mnt/data/config/rclone/rclone.conf
sudo rclone config --config /mnt/data/config/rclone/rclone.conf
test -f /mnt/data/config/rclone/rclone.conf
```

repo 内の `config/rclone/rclone.conf` は使いません。作成してしまった場合は、必要な内容を `/mnt/data/config/rclone/rclone.conf` へ移してから削除します。

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
sudo systemctl stop immich jellyfin
sudo systemctl start immich jellyfin
```

残している簡易スクリプト:

```bash
./scripts/ops/start-services.sh
./scripts/ops/stop-services.sh
./scripts/ops/rclone-media-sync.sh
./scripts/ops/media-backup.sh
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

sudo install -m 0644 -D docker/jellyfin/docker-compose.yml /home/mediaserver/ManageMediaServer/docker/jellyfin/docker-compose.yml
sudo install -m 0755 -D scripts/ops/apply-media-firewall.sh /home/mediaserver/ManageMediaServer/scripts/ops/apply-media-firewall.sh
sudo test -f /home/mediaserver/ManageMediaServer/config/env/media-firewall.env || sudo install -m 0644 -D config/env/media-firewall.env.example /home/mediaserver/ManageMediaServer/config/env/media-firewall.env
sudoedit /home/mediaserver/ManageMediaServer/config/env/media-firewall.env
sudo cp systemd/media-firewall.service /etc/systemd/system/
sudo systemctl daemon-reload
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
  media-daily-maintenance.service
  media-daily-maintenance.timer
  media-backup.service
  media-backup.timer
  media-app-update.service
  media-app-update.timer
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
    install-media-daily-maintenance-systemd.sh
    install-media-app-update-systemd.sh
    install-media-backup-systemd.sh
    media-daily-maintenance.sh
    media-os-update.sh
    media-app-update.sh
    media-backup.sh
    rclone-media-sync.sh
    start-services.sh
    stop-services.sh
config/
  env/
    media-firewall.env.example
    media-daily-maintenance.env.example
    media-os-update.env.example
    media-backup.env.example
    media-app-update.env.example
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

家庭内 LAN は内部ネットワークとして扱い、家庭外からのアクセスは Tailscale のプライベートネットワークを使います。

- ルーターのポート開放は行わない
- Immich/Jellyfin をインターネットへ直接公開しない
- UFW と Docker の `DOCKER-USER` chain で家庭内 LAN と Tailscale 以外からの Immich/Jellyfin への到達を許可しない
- Tailscale の WireGuard ベース暗号化を前提にする
- 家族共有が必要になった場合は Tailscale のユーザー・デバイス管理で許可する
- HTTPS が必要な場合は Tailscale Serve を使う
- Tailscale Serve の証明書は MagicDNS と HTTPS Certificates に任せ、Immich/Jellyfin 側では管理しない

通常のアクセスは、家庭内では LAN IP、家庭外では `100.x.x.x:2283` / `100.x.x.x:8096` または MagicDNS 名を使います。
HTTPS を使う場合は、Tailscale 接続中の端末から以下へアクセスします。

```text
Immich:  https://home-ubuntu.tail1bf795.ts.net/
Jellyfin: https://home-ubuntu.tail1bf795.ts.net:8443/
```

### rclone の同期設計は docs に分ける

rclone の同期方針、画像と動画の扱い、削除操作の安全条件は [docs/同期設計.md](docs/同期設計.md) にまとめます。

通常運用では `rclone-media-sync.timer` を直接使わず、`media-daily-maintenance.timer` が `rclone-media-sync.sh` を部品として呼びます。旧構成の単体 timer は daily AM 8:00 JST でしたが、日次メンテナンス導入後は無効化します。

```ini
OnCalendar=*-*-* 08:00:00 Asia/Tokyo
```

旧 `rclone-sync.timer` は `rclone sync` による削除反映リスクがあるため、通常運用では使いません。

### rclone-media-sync の配置

本番で `rclone-media-sync.service` が呼ぶ正のスクリプトは `/home/mediaserver/ManageMediaServer/scripts/ops/rclone-media-sync.sh` です。`/home/mediaserver/ManageMediaServer` は Git checkout ではなく、本番配置コピーとして扱います。変更後は Git checkout から本番配置へ `scripts/`, `config/`, `systemd/`, `docs/` を反映します。

```bash
test -x /home/mediaserver/ManageMediaServer/scripts/ops/rclone-media-sync.sh
test -f /home/mediaserver/ManageMediaServer/config/rclone/media-sync-excludes.txt
test -f /mnt/data/config/rclone/rclone.conf
```

単体 systemd unit/timer を配置する場合:

```bash
sudo cp systemd/rclone-media-sync.service /etc/systemd/system/
sudo cp systemd/rclone-media-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
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
- 通常運用では `rclone-media-sync.timer` も disabled / inactive
- 日次実行対象には `media-daily-maintenance.timer` だけが出る

問題が出た場合は、まず削除なしの手動実行へ退避します。

```bash
sudo systemctl stop rclone-media-sync.timer
sudo systemctl disable rclone-media-sync.timer
./scripts/ops/rclone-media-sync.sh --no-delete
```

旧 `rclone-sync.timer` の再有効化は `rclone sync` の削除反映リスクがあるため、最終手段として扱います。

### media-backup の配置

通常運用では `media-backup.timer` を直接使わず、`media-daily-maintenance.timer` が `media-backup.sh` を最初のメディア処理として呼びます。旧構成の単体 timer は daily AM 4:00 JST でしたが、日次メンテナンス導入後は無効化します。

```ini
OnCalendar=*-*-* 04:00:00 Asia/Tokyo
```

本番で `media-backup.service` が呼ぶ正のスクリプトは `/home/mediaserver/ManageMediaServer/scripts/ops/media-backup.sh` です。反映には配置用スクリプトを使います。

```bash
./scripts/ops/install-media-backup-systemd.sh
```

配置後の期待状態:

- 通常運用では `media-backup.timer` は disabled / inactive
- 日次実行対象には `media-daily-maintenance.timer` だけが出る
- `/mnt/backup` が mountpoint
- `/mnt/backup/immich-upload`
- `/mnt/backup/immich-backup`
- `/mnt/backup/jellyfin-backup`
- `/mnt/data/config/media-backup/logs/media-backup.log`

このバックアップはメディアファイルの退避専用です。Immich PostgreSQL、Jellyfin 設定、サムネイル、キャッシュ、ユーザー操作履歴の完全復元は対象外です。アプリケーション移行時は、バックアップ先のメディアファイルを新しいアプリケーションへ再取り込みします。

### 日次メンテナンスバッチの設計

日次運用は `media-daily-maintenance.timer` を唯一の定期実行入口にします。個別の `media-backup.timer`、`media-app-update.timer`、`rclone-media-sync.timer` は通常運用では無効化し、各 service / script は手動実行または日次メンテナンスから呼ばれる部品として残します。

`media-daily-maintenance.service` は root で `/home/mediaserver/ManageMediaServer/scripts/ops/media-daily-maintenance.sh` を呼びます。メディア処理は `mediaserver` ユーザーで実行し、OS 更新だけ root で実行します。

systemd unit:

| unit | 時刻 | 役割 |
| --- | --- | --- |
| `media-daily-maintenance.timer` | daily AM 4:00 JST | バックアップ、アプリ更新、rclone 同期、OS 更新、必要時の再起動を直列実行 |

処理順序:

1. 全体 lock を取得する
2. メディアバックアップを実行する
3. Immich/Jellyfin を同一 major 内で更新する
4. rclone でクラウドストレージからメディアを取り込み、バックアップ確認済み動画をクラウド側から削除する
5. apt / snap による OS・パッケージ更新を実行する
6. `/var/run/reboot-required` があれば、日次処理完了後に自動再起動を予約する
7. Discord へ日次結果を 1 本だけ通知する

OS や Docker daemon、Tailscale、kernel は更新時に daemon restart や再起動を伴う可能性があるため、OS 更新は最後に行います。これにより、バックアップ・アプリ更新・同期を終えてから OS 更新と再起動で締める運用にします。

日次メンテナンス配下では、個別スクリプトの Discord 通知は `SUPPRESS_DISCORD=true` で抑止します。各スクリプトは `SUMMARY_FILE` に実行結果を書き出し、親スクリプトが 1 本の Discord 通知に集約します。

日次メンテナンスの導入:

```bash
./scripts/ops/install-media-daily-maintenance-systemd.sh
```

この導入スクリプトは以下を行います。

- `media-daily-maintenance.timer` を enable / start する
- `media-backup.timer`、`media-app-update.timer`、`rclone-media-sync.timer`、`apt-daily-upgrade.timer` を disable / stop する
- 個別 service と script は削除せず、手動実行用として残す

確認:

```bash
systemctl status media-daily-maintenance.timer --no-pager
systemctl list-timers media-daily-maintenance.timer --no-pager
journalctl -u media-daily-maintenance.service -n 100 --no-pager
sudo tail -100 /mnt/data/config/media-daily-maintenance/logs/media-daily-maintenance.log
```

手動確認:

```bash
sudo ./scripts/ops/media-daily-maintenance.sh --check-only
sudo ./scripts/ops/media-daily-maintenance.sh --dry-run
```

停止する場合:

```bash
sudo systemctl disable --now media-daily-maintenance.timer
```

### アプリ更新バッチの設計

Immich/Jellyfin のセキュリティアップデートを人手で追い続ける運用は現実的ではないため、アプリ更新は日次メンテナンス内で処理します。ただし major 更新は破壊的変更を含む可能性があるため、自動適用せず日次通知内の warning として報告します。

`media-app-update.service` は `/home/mediaserver/ManageMediaServer/scripts/ops/media-app-update.sh` を呼びます。処理順序は以下です。

1. `/mnt/backup` が mountpoint であることを確認する
2. 単体実行時は `media-backup.service` の直近実行が成功していることを確認する
3. `/`, `/mnt/data`, `/mnt/backup` の空き容量を確認する
4. GitHub Releases から Immich/Jellyfin の最新 major を確認する
5. 現在の固定 major より新しい major があれば、更新せずサマリへ warning として書き出す
6. major が同じ範囲の更新だけ `docker compose pull && docker compose up -d` で適用する
7. `docker compose ps` と HTTP 疎通で Immich/Jellyfin の起動状態を確認する
8. 成功、更新なし、失敗、major 更新検知をサマリへ書き出す

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

単体 systemd timer は通常運用では使いません。手動確認:

```bash
systemctl status media-app-update.timer --no-pager
journalctl -u media-app-update.service -n 100 --no-pager
sudo tail -100 /mnt/data/config/media-app-update/logs/media-app-update.log
```

### OS / パッケージ更新バッチの設計

OS と apt / snap パッケージの更新は `media-os-update.sh` が担当します。日次メンテナンスの最後に実行し、`apt-get update`、`apt-get -y full-upgrade`、`snap refresh` を実行します。

対象:

| 種別 | 処理 | 備考 |
| --- | --- | --- |
| Ubuntu / apt | `apt-get update && apt-get -y full-upgrade` | Ubuntu 標準、Docker、Tailscale など apt repository 由来の更新を含む |
| apt cleanup | `apt-get -y autoremove` | 既定では無効。必要な場合だけ `RUN_APT_AUTOREMOVE=true` で有効化 |
| snap | `snap refresh` | snap パッケージを更新。`snap` がない場合は警告のみ |
| reboot | `/var/run/reboot-required` を確認 | 必要なら日次処理完了後に自動再起動を予約 |

既定では `AUTO_REBOOT=true`、`AUTO_REBOOT_DELAY_MINUTES=5` です。再起動が必要な場合、Discord 通知に `reboot: scheduled_in_5_minutes` と記録してから `shutdown -r +5` を実行します。夜間に人間の判断を要求する通知は出しません。

標準の `apt-daily.timer` は package list 更新として残しても問題ありませんが、実際の upgrade は `media-os-update.sh` に一本化するため、導入時に `apt-daily-upgrade.timer` は無効化します。

手動確認:

```bash
sudo ./scripts/ops/media-os-update.sh --check-only
sudo ./scripts/ops/media-os-update.sh --dry-run
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

日次運用では Discord 通知は `media-daily-maintenance.sh` だけが送ります。個別バッチは日次配下では通知を抑止し、実行結果だけを親スクリプトへ渡します。通知は成功・失敗・warning・再起動予約のいずれでも 1 日 1 本です。

通知に含める主な内容:

```text
**media daily maintenance succeeded**

host: `home-ubuntu`
time: `2026-05-24 05:58:12 JST`
duration: `1h 34m`
result: `succeeded`

steps:
- media backup: `ok`
- app update: `ok`
- rclone sync: `ok`
- os update: `ok`
- reboot: `not_required`

sync:
- image copy: `succeeded`
- video copy: `succeeded`
- sync backup: `succeeded`
- verified videos: `123`
- deleted videos: `123`
- skipped videos: `0`
- dry-run: `false`
- no-delete: `false`

backup:
- targets: `immich-upload, immich-external, jellyfin-media`

app updates:
- latest: `Immich=v2.x.x; Jellyfin=v10.x.x`
- updated containers: `none`
- major updates: `none`

os updates:
- apt upgraded: `tailscale, snapd`
- apt upgraded count: `2`
- snap refreshed: `none`
- snap refreshed count: `0`
- autoremove: `disabled`
- reboot required: `no`
- reboot required by: `none`

storage:
- `/`: `42.1G free / 20% used`
- `/mnt/data`: `512G free / 55% used`
- `/mnt/backup`: `1.8T free / 44% used`

logs:
- daily: `/mnt/data/config/media-daily-maintenance/logs/media-daily-maintenance.log`
- backup: `/mnt/data/config/media-backup/logs/media-backup.log`
- app update: `/mnt/data/config/media-app-update/logs/media-app-update.log`
- sync: `/mnt/data/config/rclone/logs/media-sync.log`
- os update: `/mnt/data/config/media-os-update/logs/media-os-update.log`
```

`skipped videos` が 0 でない場合、または Immich/Jellyfin の major 更新を検知した場合は、日次通知のタイトルを `completed with warnings` にします。再起動が必要で自動再起動を予約した場合は、タイトルを `completed; reboot scheduled` にします。

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

### Tailscale Serve

HTTPS が必要な場合は、Tailscale Serve で `home-ubuntu.tail1bf795.ts.net` に HTTPS endpoint を作ります。`443/tcp` は Immich、`8443/tcp` は Jellyfin へ転送します。

```bash
tailscale serve status
tailscale funnel status
sudo tailscale serve --bg --https=443 http://127.0.0.1:2283
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8096
tailscale serve status
tailscale funnel status
```

`tailscale funnel status` に endpoint が表示されても、`(tailnet only)` であれば Funnel による公開ではありません。

期待する URL:

```text
Immich:  https://home-ubuntu.tail1bf795.ts.net/
Jellyfin: https://home-ubuntu.tail1bf795.ts.net:8443/
```

停止する場合:

```bash
sudo tailscale serve --https=443 off
sudo tailscale serve --https=8443 off
tailscale serve status
tailscale funnel status
```

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
- `docker/immich/docker-compose.yml`
- `docker/immich/.env.example`
- `docker/jellyfin/docker-compose.yml`
- `config/env/*.env.example`
- `scripts/ops/*.sh`
- `systemd/*.service`
- `systemd/*.timer`
- 設定テンプレート

管理しないもの:

- 実データ
- バックアップ
- ログ
- `.env`
- `rclone.conf`
- `notification.env`
- `media-firewall.env`
- `media-daily-maintenance.env`
- `media-os-update.env`
- `media-backup.env`
- `media-app-update.env`
- 認証情報

## ライセンス

MIT License
