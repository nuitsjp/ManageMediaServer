# メディアサーバー移行作業詳細

## 概要
家庭用メディアサーバーのバックアップディスクをNTFSからext4に変換し、既存データを適切なサービス別ディレクトリに整理して復元する作業。

## ✅ 完了した作業

### 1. ✅ データ退避完了（2025-05-31）
- 全メディアデータ（235GB）を/tmp/backup-migration/に一時退避
- Pictures(21GB), Home Videos(13GB), Music Videos(201GB)の退避完了
- 権限問題解決（ubuntu:ubuntu所有者変更）

### 2. ✅ バックアップディスクのext4変換完了（2025-05-31）
- /dev/sda1をNTFSからext4にフォーマット（ラベル: "MediaBackup"）
- UUID: b5afccae-200c-4013-9b41-b832f5c1ef49
- /etc/fstabに永続マウント設定追加
- /mnt/backupにマウント（880GB利用可能、602GB空き）

### 3. ✅ サービス別データ整理完了（2025-05-31）
- /mnt/backup/immich-backup/（33GB）: Pictures + Home Videos統合
- /mnt/backup/jellyfin-backup/（201GB）: Music Videos
- サブディレクトリからファイルを親ディレクトリに移動完了

### 4. ✅ メディアデータのサービスディレクトリへの移動完了（2025-05-31）
**実行内容**:
- Pictures + Home Videos → `/mnt/data/immich/external/` (直下に配置)
- Music Videos → `/mnt/data/jellyfin/` (直下に配置)
- 権限設定: ubuntu:ubuntu
- サブディレクトリ構造は作成せず、全ファイルを直下に移動

**実行結果**:
```bash
# Immich外部ライブラリ
/mnt/data/immich/external/: 21GB, 4,705ファイル

# Jellyfinライブラリ  
/mnt/data/jellyfin/: 185GB, 37ファイル

# 全体のディスク使用量
NVMeディスク: 220GB使用, 226GB空き (50%使用率)
```

### 5. ✅ 一時退避データのクリーンアップ完了（2025-05-31）
- /tmp/backup-migration/ ディレクトリ削除完了
- /tmp/backup-temp/ ディレクトリ削除完了

### 6. ✅ ドキュメント更新完了（2025-05-31）
- server-configuration.md: バックアップディスク情報更新
- TODO_DETAIL.md: 作業完了状況の記録

## 🎯 作業完了サマリー

**移行データ総量**: 235GB → 206GB (圧縮効果あり)
- **Immich**: Pictures(21GB) + Home Videos(13GB) → 21GB
- **Jellyfin**: Music Videos(201GB) → 185GB

**最終的な物理構成**:

```
/dev/nvme0n1 (477GB) - プライマリディスク
└─ ubuntu-lv (473.9GB): / (ルートファイルシステム)
   ├─ /home (PROJECT_ROOT)
   ├─ /var (Docker・ログ)
   └─ /mnt/data (メディアストレージ)
      ├─ /mnt/data/immich/external/ (21GB, 4,705ファイル)
      └─ /mnt/data/jellyfin/ (185GB, 37ファイル)

/dev/sda1 (894GB) - バックアップディスク（ext4）
└─ /mnt/backup (マウント済み)
   ├─ immich-backup/ (33GB, 保持)
   ├─ jellyfin-backup/ (201GB, 保持)  
   └─ system-backup/ (今後使用)
```

## 📋 次の推奨作業

### A. Immich外部ライブラリの設定
1. Immich Web UIにアクセス
2. 管理画面 → 外部ライブラリ追加
3. パス: `/usr/src/app/external` (コンテナ内パス)
4. ライブラリスキャン実行

### B. Jellyfinライブラリの再スキャン
1. Jellyfin Web UIにアクセス  
2. ダッシュボード → ライブラリ
3. ライブラリ再スキャン実行

### C. バックアップ戦略の確立
- 定期的なメディアファイルバックアップ設定
- システム設定のバックアップ自動化
- /mnt/backup/system-backup/ の活用

## 🔒 セキュリティと安全性

**達成された物理分離**:
- ✅ メディア運用: NVMeディスク（高速・信頼性）
- ✅ バックアップ運用: SATA SSD（物理分離・容量重視）  
- ✅ リスク分散: ディスク故障時の影響範囲限定

**容量管理**:
- ✅ NVMe: 226GB空き容量（今後の拡張余地）
- ✅ SATA: 602GB空き容量（バックアップ十分な余裕）

### 現在の残作業 🔄

#### 4. メディアデータのサービスディレクトリコピー

**目的**: バックアップからサービス用ディレクトリへのデータ配置

**作業概要**:
1. Immichデータのコピー: `/mnt/backup/immich-backup/` → Immich外部ライブラリ
2. Jellyfinデータのコピー: `/mnt/backup/jellyfin-backup/` → Jellyfinメディアライブラリ

**詳細手順**:

##### 4.1 Immichライブラリへのコピー

```bash
# 1. Immich外部ライブラリディレクトリ準備
sudo mkdir -p /mnt/data/immich/library
sudo chown -R ubuntu:ubuntu /mnt/data/immich/library
sudo chmod -R 755 /mnt/data/immich/library

# 2. データコピー実行（33GB）
# 推定時間: 10-15分（NVMe ← SATA間コピー）
rsync -av --progress /mnt/backup/immich-backup/ /mnt/data/immich/library/

# 3. 権限確認・修正
sudo chown -R ubuntu:ubuntu /mnt/data/immich/library
find /mnt/data/immich/library -type d -exec chmod 755 {} \;
find /mnt/data/immich/library -type f -exec chmod 644 {} \;

# 4. コピー結果確認
du -sh /mnt/data/immich/library
ls -la /mnt/data/immich/library/
```

##### 4.2 Jellyfinライブラリへのコピー

```bash
# 1. Jellyfinメディアライブラリディレクトリ準備
sudo mkdir -p /mnt/data/jellyfin/media/music-videos
sudo chown -R ubuntu:ubuntu /mnt/data/jellyfin/media
sudo chmod -R 755 /mnt/data/jellyfin/media

# 2. データコピー実行（201GB）
# 推定時間: 40-60分（大容量ビデオファイル）
rsync -av --progress /mnt/backup/jellyfin-backup/ /mnt/data/jellyfin/media/music-videos/

# 3. 権限確認・修正
sudo chown -R ubuntu:ubuntu /mnt/data/jellyfin/media
find /mnt/data/jellyfin/media -type d -exec chmod 755 {} \;
find /mnt/data/jellyfin/media -type f -exec chmod 644 {} \;

# 4. コピー結果確認
du -sh /mnt/data/jellyfin/media/music-videos
ls -la /mnt/data/jellyfin/media/music-videos/
```

##### 4.3 容量確認・検証

```bash
# 1. 全体容量確認
df -h /mnt/data
du -sh /mnt/data/immich/library
du -sh /mnt/data/jellyfin/media/music-videos

# 2. ファイル数確認
find /mnt/data/immich/library -type f | wc -l
find /mnt/data/jellyfin/media/music-videos -type f | wc -l

# 3. バックアップとの整合性確認
# Immich（写真・動画）
find /mnt/backup/immich-backup -type f | wc -l
find /mnt/data/immich/library -type f | wc -l

# Jellyfin（ミュージックビデオ）
find /mnt/backup/jellyfin-backup -type f | wc -l
find /mnt/data/jellyfin/media/music-videos -type f | wc -l
```

#### 5. 一時退避データのクリーンアップ

**目的**: /tmp/backup-migration/と/tmp/backup-temp/の削除

```bash
# 1. コピー完了後の確認
ls -la /tmp/backup-migration/
ls -la /tmp/backup-temp/

# 2. 容量確認（削除予定サイズ）
du -sh /tmp/backup-migration/
du -sh /tmp/backup-temp/

# 3. 削除実行
sudo rm -rf /tmp/backup-migration/
sudo rm -rf /tmp/backup-temp/

# 4. 削除確認
ls /tmp/ | grep backup
```

### 実行予定スケジュール

| タスク | 推定時間 | データ量 | 備考 |
|--------|----------|----------|------|
| 4.1 Immichコピー | 10-15分 | 33GB | 写真・ホームビデオ |
| 4.2 Jellyfinコピー | 40-60分 | 201GB | ミュージックビデオ |
| 4.3 検証・確認 | 5-10分 | - | 整合性チェック |
| 5. クリーンアップ | 2-5分 | 235GB削除 | 一時ファイル削除 |
| **合計** | **60-90分** | **234GB移動** | **バックアップ完了** |

### 想定される最終構成

#### メディアストレージ（/mnt/data - NVMe）
```
/mnt/data/
├── immich/
│   └── library/          # 33GB（写真・ホームビデオ統合）
├── jellyfin/
│   └── media/
│       └── music-videos/ # 201GB（ミュージックビデオ）
└── cache/                # キャッシュ・一時ファイル
```

#### バックアップストレージ（/mnt/backup - SATA SSD）
```
/mnt/backup/
├── immich-backup/        # 33GB（バックアップコピー）
├── jellyfin-backup/      # 201GB（バックアップコピー）
└── system-backup/        # 将来のシステムバックアップ用
```

### 注意事項・リスク管理

1. **容量チェック**: 各コピー前にディスク容量を確認
2. **権限確認**: サービスからのアクセス可能性を検証
3. **整合性検証**: ファイル数・サイズの一致確認
4. **バックアップ保持**: 一時退避データは検証完了後に削除

### 次回以降のタスク（将来）

- [ ] Immich外部ライブラリの設定・認識確認
- [ ] Jellyfinライブラリスキャン・メタデータ取得
- [ ] システムバックアップスクリプトの作成
- [ ] 定期バックアップの自動化設定