# Immich管理スクリプト（WSL環境用）

このディレクトリには、Windows 11のWSL（Windows Subsystem for Linux）環境上でImmich写真管理サービスを
導入・管理するためのPowerShellスクリプトが含まれています。

## 前提条件

- Windows 11
- WSLが有効化されていること
- PowerShell 7以上（Windows PowerShellでも動作しますが、PowerShell 7を推奨）

## 各スクリプトの説明

### Start-Immich.ps1

Immichサービスを導入し、起動するためのスクリプトです。初回実行時には以下の処理を行います：

1. WSLのUbuntuディストリビューションがない場合は自動インストール
2. Docker未導入の場合はWSL内にDockerをインストール・起動
3. 必要なImmichの設定ファイル（docker-compose.yml, .env）の作成
4. 画像アップロード用ディレクトリとデータベース用ディレクトリの作成
5. Immichサービスの起動

実行方法：
```
.\Start-Immich.ps1
```

### Stop-Immich.ps1

実行中のImmichサービスを停止するためのスクリプトです。

実行方法：
```
.\Stop-Immich.ps1
```

### Status-Immich.ps1

Immichサービスの状態を確認するスクリプトです。実行中のコンテナ、ログ、サーバーの応答状態を表示します。

実行方法：
```
.\Status-Immich.ps1
```

## 設定について

初回実行時に以下の設定値を尋ねられます（または既定値が提案されます）：

- 画像アップロードパス（既定値: D:\immich-photos）
- PostgreSQLデータベースパス（既定値: D:\immich-postgres）
- タイムゾーン（既定値: Asia/Tokyo）

これらの設定値はシステム環境変数に保存され、以後のスクリプト実行時に再利用されます。
設定を変更する場合は、Windowsのシステム環境変数から以下の値を削除してください：

- IMMICH_UPLOAD_LOCATION
- IMMICH_DB_DATA_LOCATION
- IMMICH_TIMEZONE

## アクセス方法

Immichサービスが起動したら、以下のURLでアクセスできます：

```
http://localhost:2283
```

初回アクセス時は管理者アカウントの作成が必要です。
