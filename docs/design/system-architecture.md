# システム設計

## 全体構成

家庭用メディアサーバーシステムの全体構成と各コンポーネントの関係を説明します。

### システム構成図

```mermaid
flowchart TB
    subgraph HomeNetwork[Home network]
        subgraph ClientPC[クライアントPC]
            MovieSource[Jellyfin用動画]
        end

        subgraph LinuxServer[Ubuntu Server]
            ImmichLibrary[Immich外部ライブラリ]
            BackupStorage@{ shape: lin-cyl, label: "バックアップストレージ" }
            JellyfinLib[Jellyfinライブラリ]
            rclone
            Immich
            Jellyfin
        end
    end

    subgraph ClientNetwork[Home network or Internet]
        Smartphone[スマートフォン]
    end

    subgraph InternetServices[Internet]
        CloudStrage@{ shape: lin-cyl, label: "クラウドストレージ" }
        CloudflareTunnel[Cloudflare Tunnel/Access]
    end
 
    Smartphone -- 画像・動画視聴 --> CloudflareTunnel
    Smartphone -- 画像・動画アップロード --> CloudStrage

    MovieSource -- 手動コピー --> JellyfinLib
    JellyfinLib -- バックアップ --> BackupStorage
    ImmichLibrary -- 動画のみバックアップ --> BackupStorage
    CloudStrage --画像・動画の取得（動画は取得時に削除）--> rclone
    rclone --保存--> ImmichLibrary
    CloudflareTunnel --> Immich
    CloudflareTunnel --> Jellyfin

    Immich -.-> ImmichLibrary
    Jellyfin -.-> JellyfinLib
```

## データフロー詳細

### 1. 画像・短尺動画フロー

#### 対象ファイル形式
- **画像**: JPG (3,502ファイル), PNG (735ファイル) 
- **動画**: MOV (413ファイル), MP4/mp4 (54ファイル)

#### 処理フロー
1. **アップロード**: スマートフォン → クラウドストレージ（自動）
2. **同期処理**: rclone → クラウドストレージから取得
   - **画像（JPG/PNG）**: 同期のみ（クラウド側保持）
   - **動画（MOV/MP4）**: ダウンロード後、クラウド側を削除
3. **保存**: Immich外部ライブラリに配置
4. **バックアップ**: 動画ファイルのみバックアップストレージにコピー
5. **公開**: Immichを通じて閲覧可能

### 2. 長尺動画フロー

1. **転送**: クライアントPC → Jellyfinライブラリ（手動）
2. **バックアップ**: Jellyfinライブラリ → バックアップストレージ
3. **公開**: Jellyfinを通じて閲覧可能

### 3. アクセスフロー

1. **内部アクセス**: ホームネットワーク → 直接アクセス
2. **外部アクセス**: インターネット → Cloudflare → サーバー

## 重要な設計決定

### バックアップ方針

- **画像（JPG/PNG）**: バックアップなし（クラウドストレージが元データとして保持）
- **短尺動画（MOV/MP4）**: バックアップあり（クラウドから移動するため、消失防止が必要）
- **長尺動画**: バックアップあり（オリジナルデータ保護）

#### ファイル種別ごとの取り扱い詳細
- **画像ファイル**: 4,237ファイル（総容量の約90%）
  - 同期処理でローカルコピーを作成
  - クラウド側は削除せず原本として保持
- **動画ファイル**: 468ファイル（総容量の約10%）
  - ダウンロード後にクラウド側を削除（容量節約）
  - バックアップストレージに必ずコピー

### セキュリティ方針

- **外部アクセス**: Cloudflare Accessによるホワイトリスト制御
- **内部アクセス**: 直接アクセス（信頼できるネットワーク前提）
- **データ保護**: バックアップディスクによる冗長化

### 可用性方針

- **RAID不使用**: シンプルな構成を優先
- **単一障害点**: 許容（家庭用途のため）
- **復旧方針**: バックアップからの手動復旧

## ファイル統計情報

### 現在の保存状況（2025年6月現在）

#### Immich外部ライブラリ統計
- **総ファイル数**: 4,705ファイル
- **画像ファイル**: 4,237ファイル（90%）
  - JPG: 3,502ファイル
  - PNG: 735ファイル
- **動画ファイル**: 468ファイル（10%）
  - MOV: 413ファイル
  - mp4: 51ファイル
  - MP4: 3ファイル
  - mov: 1ファイル

#### データ期間
- **対象期間**: 2014年〜2025年（約11年間）
- **主要デバイス**: iPhone、Android（Pixel）、スクリーンショット

#### ファイル命名パターン
- `YYYYMMDD_HHMMSS000_iOS.*` - iOSデバイス
- `PXL_YYYYMMDD_HHMMSS.*` - Google Pixelデバイス
- `IMG_YYYYMMDD_HHMMSS.*` - Android標準カメラ
- `Screenshot_YYYYMMDD-HHMMSS.*` - スクリーンショット
