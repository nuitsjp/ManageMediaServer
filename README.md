# 概要

本リポジトリは、家庭用のメディアサーバーをWindows 11 Home環境で構築・運用するためのスクリプトや設定ファイルを管理しています。家庭内のミニPCなどにWindows 11をホストとして導入し、スマートフォンで撮影した画像や動画を効率的かつ安全に管理・公開することを目的としています。

スマートフォンで撮影した画像や動画は、まずクラウドストレージにアップロードされます。画像はrcloneを利用してWindowsサーバー上のImmich外部ライブラリにコピーされ、動画は一旦バックアップストレージに保存した後、同様にImmich外部ライブラリへコピーされます。これにより、画像はクラウドストレージと外部ライブラリの二重で保持され、動画は物理的に異なるドライブ間で管理されるため、安全性を高めています。

公開方法としては、画像や短い動画はImmichを通じて、長尺動画はJellyfinを利用して家庭内ユーザーに提供します。外部からのアクセスについては、Cloudflare TunnelおよびCloudflare Accessを活用し、ホワイトリストに登録されたユーザーのみが安全にサーバーへアクセスできるように設計しています。

なお、RAIDや追加バックアップは基本的に利用せず、必要に応じてオプションとして検討する方針です。セットアップや運用の自動化は現在進行中であり、今後も本リポジトリで一元的に管理・拡充していきます。

- 本リポジトリの主な構成要素
  - Immichによる画像・動画の公開
  - Jellyfinによる長尺動画の公開
  - rcloneによるクラウドストレージ連携
  - Cloudflare Tunnel/Accessによる外部アクセス制御

---

## 構成図

```mermaid
flowchart TD
    A[スマートフォン] -- 画像・動画アップロード --> B[クラウドストレージ]
    B -- rcloneで画像コピー --> C[Immich外部ライブラリ]
    B -- rcloneで動画移動 --> D[バックアップストレージ]
    F[Jellyfin用動画] -- 手動コピー --> G[Jellyfinライブラリ]
    G -- 自動バックアップ --> D
    D -- コピー --> C
    C -- Immichで公開 --> E[家庭内ユーザー]
    G -- Jellyfinで公開 --> E
    subgraph H[Windows 11サーバー]
        C
        D
        G
    end
    I[Cloudflare Tunnel/Access] -- 外部アクセス制御 --> H
    J[ホワイトリスト外部ユーザー] -- 認証後アクセス --> I
```

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
