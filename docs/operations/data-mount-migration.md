# /mnt/data 専用マウント移行手順

`/mnt/data` は Immich/Jellyfin/rclone の主要データ領域です。ルートファイルシステム直下の通常ディレクトリとして運用すると、メディア増加で OS 領域を圧迫します。専用ディスクまたは専用 LVM 論理ボリュームとしてマウントしてください。

## 前提確認

```bash
mountpoint /mnt/data
df -h / /mnt/data /mnt/backup
lsblk -f
sudo systemctl status immich jellyfin rclone-sync.timer
```

`mountpoint /mnt/data` が失敗する場合、現在の `/mnt/data` はルートファイルシステム上の通常ディレクトリです。

## 移行方針

1. `/mnt/backup` に最新バックアップを作成する
2. Immich/Jellyfin/rclone を停止する
3. 新しいデータ領域を `/mnt/data.new` などへ一時マウントする
4. `rsync` で所有者・権限を保持してコピーする
5. `/etc/fstab` を更新し、新領域を `/mnt/data` にマウントする
6. サービスを起動して動作確認する

## 手順

```bash
# 1. サービス停止
sudo systemctl stop rclone-sync.timer
sudo systemctl stop immich jellyfin

# 2. 新データ領域を一時マウント
sudo mkdir -p /mnt/data.new
sudo mount /dev/disk/by-uuid/<DATA_UUID> /mnt/data.new

# 3. データコピー
sudo rsync -aHAX --numeric-ids /mnt/data/ /mnt/data.new/

# 4. fstab 更新前の確認
sudo rsync -aHAXn --numeric-ids --delete /mnt/data/ /mnt/data.new/
sudo blkid /dev/disk/by-uuid/<DATA_UUID>

# 5. /etc/fstab に追加
# /dev/disk/by-uuid/<DATA_UUID> /mnt/data ext4 defaults,nofail 0 2

# 6. 旧ディレクトリを退避し、新領域を /mnt/data にマウント
sudo mv /mnt/data /mnt/data.old
sudo mkdir -p /mnt/data
sudo mount /mnt/data

# 7. 権限確認
sudo chown -R mediaserver:mediaserver /mnt/data
sudo chmod 755 /mnt/data
mountpoint /mnt/data
df -h /mnt/data

# 8. サービス起動
sudo systemctl start immich jellyfin
sudo systemctl start rclone-sync.timer
```

## 動作確認

```bash
curl -I --max-time 5 http://localhost:2283
curl -I --max-time 5 http://localhost:8096
sudo systemctl status immich jellyfin rclone-sync.timer --no-pager
```

問題がなければ、数日運用後に `/mnt/data.old` を削除します。削除前に `/mnt/backup` 側のバックアップが最新であることを確認してください。
