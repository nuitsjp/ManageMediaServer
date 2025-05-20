# 概要

本リポジトリは、家庭用のメディアサーバーをWindows 11 Home環境で構築・運用するためのスクリプトや設定ファイルを管理します。家庭内のミニPCなどにWindows 11をホストとして導入し、スマートフォンで撮影した画像や動画を効率的かつ安全に管理・公開することを目的とします。

## システム概要

本システムでは、家族の画像や動画を安全かつ効率的に管理・公開するためのメディアサーバーを構築します。Windows 11 Homeをベースとし、Docker上でImmichとJellyfinを実行して、スマートフォンで撮影したメディアを一元管理します。

### 視聴方法

画像や短い動画はImmichを通じて、長尺動画はJellyfinを利用して家庭内ユーザーに提供します。外部からのアクセスについては、Cloudflare TunnelおよびCloudflare Accessを活用し、ホワイトリストに登録されたユーザーのみが安全にサーバーへアクセスできるように設計します。スマートフォンからはCloudflare経由でImmichとJellyfinにアクセスし、撮影した画像や動画を閲覧できます。

### データフロー

スマートフォンで撮影した画像や動画は、端末内のクラウドストレージアプリ（Google Photos、OneDriveなど）によって自動的にクラウドストレージにアップロードされます。**Windows 11サーバー上で動作するrclone**がインターネット上のクラウドストレージに接続し、画像や動画ファイルを検出して**ホームネットワーク内**のImmich外部ライブラリにダウンロードします。その際、動画はクラウドストレージから取得後に削除されます。ダウンロードされた動画はImmich外部ライブラリからバックアップストレージにもバックアップを取ります。

長尺動画については、Windows 11クライアントから手動でJellyfinライブラリにコピーし、Jellyfinを通じて視聴します。Jellyfinライブラリのデータもバックアップストレージにバックアップを取ります。

以下の構成図は、データの流れと主要コンポーネントの関係を示します：

```mermaid
flowchart TB

    subgraph HomeNetwork[Home network]
        subgraph Win11Client[Windows 11クライアント]
            MovieSource[Jellyfin用動画]
        end

        subgraph MediaServer[Windows 11 Home サーバー]
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

このシステムの重要なポイント:

1. **データの流れ**：スマートフォン → クラウドストレージ → rclone → Immich外部ライブラリ
2. **アクセスの流れ**：スマートフォン → Cloudflare → Immich/Jellyfin → 各ライブラリ
3. **バックアップ方針**：Immich外部ライブラリの動画 → バックアップストレージ、Jellyfinライブラリ → バックアップストレージ

なお、RAIDや追加バックアップは基本的に利用せず、必要に応じてオプションとして検討する方針です。セットアップや運用の自動化は現在進行中であり、今後も本リポジトリで一元的に管理・拡充します。

### 主要コンポーネント

- Immichによる画像・動画の公開
- Jellyfinによる長尺動画の公開
- rcloneによるクラウドストレージ連携
- Cloudflare Tunnel/Accessによる外部アクセス制御

---

## Windows 11サーバーの物理構成

```mermaid
flowchart TD
    subgraph Windows11[Windows 11サーバー]
        C@{ shape: lin-cyl, label: "Cドライブ" }
        D@{ shape: lin-cyl, label: "Dドライブ" }

        C-note@{ shape: braces, label: "OS・アプリケーション\nバックアップ" }
        D-note@{ shape: braces, label: "Immich外部ライブラリ\nJellyfinライブラリ" }

        C-note -.-> C
        D-note -.-> D
    end
```

---
