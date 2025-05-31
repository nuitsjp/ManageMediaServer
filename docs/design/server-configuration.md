# サーバー構成

## 物理構成（環境別）

### 開発環境（WSL）

```
Windows 11
├── d:\ManageMediaServer\          # Git管理領域
└── WSL2 (Ubuntu 22.04)
    ├── /mnt/d/ManageMediaServer/  # PROJECT_ROOT
    ├── ~/dev-data/                # DATA_ROOT
    └── ~/dev-backup/              # BACKUP_ROOT
```

### 本番環境（Ubuntu Server）

#### ハードウェア要件

**最小構成:**
- CPU: 2コア以上
- メモリ: 4GB以上
- ストレージ: SSD 500GB + HDD 2TB

**推奨構成:**
- CPU: 4コア以上（Intel i5/AMD Ryzen 5相当）
- メモリ: 8GB以上
- ストレージ: NVMe SSD 1TB + SATA SSD 1TB

**現在の実装構成:**
- CPU: Intel N100 (4コア)
- メモリ: 16GB (7.8GB available)
- プライマリディスク: NVMe PCIe SSD 477GB
- バックアップディスク: SATA SSD 894GB (SanDisk Ultra II)

#### ディスク構成

**プライマリディスク（NVMe PCIe SSD 477GB）:**
- `/` (ルート): 473.9GB (全領域活用、LVM拡張実施済み)
- `/home`: PROJECT_ROOT領域 (ルート内)
- `/var`: Docker・ログ領域 (ルート内)
- `/mnt/data`: メディアストレージ（Immich/Jellyfin用、ルート内）

**バックアップディスク（SATA SSD 894GB - SanDisk Ultra II）:**
- `/mnt/backup`: バックアップ専用ストレージ（ext4フォーマット済み）
- 用途: メディアファイルのバックアップ、システムバックアップ
- 現在の状態: マウント済み（ext4, ラベル: "MediaBackup", UUID: b5afccae-200c-4013-9b41-b832f5c1ef49）
- 容量: 880GB使用可能、602GB空き容量

#### 物理的分離による運用方針

1. **メディア運用**: NVMeディスク（高速・信頼性）
   - Immichライブラリ
   - Jellyfinライブラリ
   - 一時ファイル・キャッシュ

2. **バックアップ運用**: SATA SSD（物理分離・容量重視）
   - メディアファイルのバックアップコピー
   - システム設定バックアップ
   - 復旧用データ

#### 現在のディスク構成詳細

```
/dev/nvme0n1 (477GB) - プライマリディスク（メディア+システム）
├─ nvme0n1p1 (1GB)    : EFI System Partition
├─ nvme0n1p2 (2GB)    : /boot
└─ nvme0n1p3 (474GB)  : LVM Physical Volume
   └─ ubuntu-lv (473.9GB): / (ルートファイルシステム、全領域利用済み)
      ├─ /home (PROJECT_ROOT)
      ├─ /var (Docker・ログ)
      └─ /mnt/data (メディアストレージ作成済み)

/dev/sda (894GB) - バックアップディスク（物理分離）
└─ sda1 (894GB)       : /mnt/backup（ext4, バックアップ専用、マウント済み）
   ├─ immich-backup/    : 写真・ホームビデオ統合バックアップ
   ├─ jellyfin-backup/  : ミュージックビデオバックアップ
   └─ system-backup/    : システム設定バックアップ
```

#### LVM拡張実施状況

**実施済み状況:**
- ルート論理ボリュームを全領域まで拡張完了
- ファイルシステムのリサイズ完了
- 拡張結果: 100GB → 473.9GB (利用可能: 432GB)

**実行されたコマンド:**
```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```

### マウント設定

```bash
# シンプル構成（物理分離、全領域活用）

# 1. ルート論理ボリュームの拡張（✅ 実施済み）
# 全領域をルートパーティションに拡張し、/mnt/data をルート内に配置

# 2. メディアディレクトリの整備（✅ 実施済み）
# /mnt/data/{immich,jellyfin,cache} ディレクトリ構造作成完了
# 権限設定 (ubuntu:ubuntu, 755) 完了

# 3. バックアップディスクの準備（✅ 完了）
sudo mkdir -p /mnt/backup
# NTFSからext4への変換済み（Linux最適化）
# sudo mkfs.ext4 -L "MediaBackup" /dev/sda1  # 実施済み
sudo mount /dev/sda1 /mnt/backup

# 4. /etc/fstab 設定（現在の設定）
/dev/disk/by-id/dm-uuid-LVM-SRXPjKOEioDrbT9A8PSaTQSnE2yYVy1XSGxuRefphgQmGwaUjP4w0wia0SxCq1jX / ext4 defaults 0 1
UUID=23d79952-dddd-41be-a97d-edfdb5dd26db /boot ext4 defaults 0 1
UUID=AB36-B95D /boot/efi vfat defaults 0 1
UUID=b5afccae-200c-4013-9b41-b832f5c1ef49 /mnt/backup ext4 defaults 0 2
```

### 権限設定

```bash
# 1. メディアストレージ設定（NVMe、ルート内）（✅ 実施済み）
# /mnt/data/{immich,jellyfin,cache} ディレクトリ構造作成完了
# 所有者設定 (ubuntu:ubuntu) と権限設定 (755) 完了

# 2. バックアップストレージ設定（SATA SSD）（✅ 完了）
sudo mkdir -p /mnt/backup
sudo mount /dev/sda1 /mnt/backup
sudo chown -R ubuntu:ubuntu /mnt/backup
sudo chmod -R 755 /mnt/backup

# 3. バックアップ用ディレクトリ構造（✅ 完了）
sudo mkdir -p /mnt/backup/{immich-backup,jellyfin-backup,system-backup}
```

### 物理分離による運用上の利点

1. **信頼性向上**
   - メディアファイルの損失リスク分散
   - ディスク故障時の影響範囲限定

2. **パフォーマンス最適化**
   - NVMeの高速性をメディアアクセスに活用
   - バックアップ処理による影響分離

3. **容量管理**
   - NVMe: 473.9GB 全領域活用（OS + メディア）
   - SATA SSD: 894GB バックアップ専用

4. **メンテナンス性**
   - バックアップディスクの独立交換・メンテナンス
   - メディア運用への影響なし

### ディスク利用最適化案

1. **NVMeディスク（477GB）- 全領域活用**
   - OS + システム: ~50GB 
   - メディアストレージ: ~350GB (Immich/Jellyfin)
   - 高速キャッシュ: ~30GB (一時ファイル・変換作業)
   - ログ・一時ファイル: ~40GB
   - 全容量活用: 473.9GB (未使用領域なし)

2. **SATA SSD（894GB）- バックアップ専用**
   - Immichバックアップ: 写真・ホームビデオ統合
   - Jellyfinバックアップ: ミュージックビデオ
   - システムバックアップ: 設定・ログ・データベース
   - 利用可能容量: ~600GB（十分な予備領域）

#### 容量設計例

**メディア想定容量（NVMe ~350GB）:**
- 写真: 100,000枚 × 2.5MB = 250GB
- 短尺動画: 6,000本 × 20MB = 120GB
- 合計: ~370GB（ほぼ全容量活用）

**バックアップ想定容量（SATA SSD ~600GB）:**
- メディアバックアップ: ~370GB（実データ分）
- システムバックアップ: ~100GB
- アーカイブ・予備領域: ~130GB

**運用方針:**
- **積極活用**: NVMeの全領域を最大限活用
- **効率重視**: 高速アクセスでメディア体験向上
- **安全確保**: 物理分離されたバックアップによる保護

### 実装完了後の最終構成

#### メディアサービス構成（実運用）

**Immichライブラリ構成**:
```
/mnt/data/immich/
├── external/          # 外部ライブラリ（写真・ホームビデオ統合）
├── upload/           # Immichアップロード領域
├── postgres/         # PostgreSQLデータベース
└── cache/            # キャッシュ・一時ファイル
```

**Jellyfinライブラリ構成**:
```
/mnt/data/jellyfin/
├── [メディアファイル]   # ミュージックビデオ直下配置
├── cache/            # Jellyfinキャッシュ
└── metadata/         # メタデータ・設定
```

#### バックアップ構成（保護・復旧用）

**バックアップストレージ構成**:
```
/mnt/backup/
├── immich-backup/    # 写真・ホームビデオバックアップ
├── jellyfin-backup/  # ミュージックビデオバックアップ
├── system-backup/    # システム設定・データベース
└── archives/         # 長期保存アーカイブ
```

#### 移行作業完了状況

**✅ 完了項目**:
- NTFSからext4への変換（Linux最適化）
- 物理的分離によるリスク分散実現
- サービス別データ整理・配置完了
- 永続マウント設定・権限設定完了
- メディアファイルの高速NVMeディスクへの配置

**📋 次段階作業**:
- Immich外部ライブラリ設定・スキャン
- Jellyfinライブラリ再構築・メタデータ取得
- 定期バックアップの自動化設定

## ネットワーク構成

### ポート設定

| サービス | ポート | 用途 |
|---------|--------|------|
| Immich | 2283 | Web UI |
| Jellyfin | 8096 | Web UI |
| SSH | 22 | 管理アクセス |
| Cloudflare Tunnel | - | 外部アクセス |

### ファイアウォール設定

```bash
# UFW設定例
sudo ufw allow ssh
sudo ufw allow from 192.168.0.0/16 to any port 2283
sudo ufw allow from 192.168.0.0/16 to any port 8096
sudo ufw enable
```

## 統一構成の詳細

統一論理構成・環境変数管理・セットアップ手順については [SCRIPT_DESIGN.md](../../SCRIPT_DESIGN.md) を参照してください。
