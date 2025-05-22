# WSLとVS Codeの連携ガイド

## 1. VS CodeからWSLへの接続方法

### 推奨方法: Remote - WSL拡張機能の利用

**最も簡単で推奨される方法**は、VS Codeの「Remote - WSL」拡張機能を使う方法です。

#### セットアップ手順:

1. **Remote - WSL拡張機能のインストール**
   - VS Code拡張機能タブで「Remote - WSL」を検索してインストール
   - または `code --install-extension ms-vscode-remote.remote-wsl` コマンドを実行

2. **WSLからVS Codeを開く方法**
   ```bash
   # WSLターミナル内で実行
   cd /mnt/d/ManageMediaServer
   code .
   ```

3. **VS Code内からWSLに接続する方法**
   - VS Code左下の緑色のアイコンをクリック
   - 「New WSL Window」を選択
   - WSLディストリビューションを選択（Ubuntu-24.04など）
   - WSL内のフォルダを開く

## 2. ファイルシステムへのアクセス方法

### Windows側からWSLのファイルにアクセスする

1. **エクスプローラーからアクセス**
   - エクスプローラーのアドレスバーに `\\wsl$` と入力
   - Ubuntuなどのディストリビューションフォルダが表示される
   - `\\wsl$\Ubuntu-24.04\home\username` などでアクセス可能

2. **VS Code Remote - WSL経由でアクセス**
   - VS CodeをWSLモードで開くと、WSLのファイルシステムにアクセス可能
   - エクスプローラーパネルでWSLのファイルを閲覧・編集可能

### WSL側からWindowsのファイルにアクセスする

1. **マウントされたドライブ経由**
   ```bash
   # Dドライブの場合
   cd /mnt/d
   
   # プロジェクトフォルダへ移動
   cd /mnt/d/ManageMediaServer
   ```

## 3. ターミナル操作

### VS CodeでWSLターミナルを開く

1. **Remote - WSLモードでVS Codeを開いた状態で**:
   - メニューから「Terminal」→「New Terminal」を選択
   - 自動的にWSLのbashターミナルが開く

2. **Windows側のVS Codeから**:
   - ターミナルのドロップダウンメニューから「Select Default Profile」を選択
   - 「WSL」や「Ubuntu-24.04」などを選択

## 4. 開発ワークフロー例

### Windowsファイル編集 + WSL実行の場合

1. **Windowsマウント方式**（推奨）:
   ```bash
   # WSLでWindowsのプロジェクトディレクトリに移動
   cd /mnt/d/ManageMediaServer
   
   # VS Codeを開く
   code .
   
   # WSLモードでスクリプトを実行
   ./scripts/install/install-docker.sh
   ```

2. **VS Code Remote方式**:
   - VS Codeで「Remote-WSL: Open Folder in WSL」を実行
   - `/mnt/d/ManageMediaServer` を選択
   - 統合ターミナルでWSLコマンドを実行

### WSL内ファイル編集 + WSL実行の場合

1. **WSLホームディレクトリで作業**:
   ```bash
   # WSLホームディレクトリにプロジェクトをクローン（オプション）
   cd ~
   git clone /mnt/d/ManageMediaServer ./mediaserver
   
   # VS Codeを開く
   cd ~/mediaserver
   code .
   ```

## 5. パフォーマンス考慮事項

### ファイルシステムアクセスの最適化

- **Windows -> WSL**: `/mnt/c/` や `/mnt/d/` 経由のアクセスは遅い場合がある
- **WSL -> Windows**: WSL内のファイルシステムへの直接アクセスが最速

### 推奨プラクティス

- **大量のファイル操作が必要な場合**: WSLのネイティブファイルシステムを使用
- **Windows側のツールが必要な場合**: Windowsファイルシステム上で作業
- **WSL内でビルド/実行する場合**: できるだけWSLファイルシステム内のファイルを使用

## 6. トラブルシューティング

### よくある問題と解決策

1. **VS CodeでWSL接続ができない**
   - WSLが起動しているか確認: `wsl --list --running`
   - VS Codeを再起動
   - Remote-WSL拡張機能を再インストール

2. **WSLでファイルの権限問題がある**
   - Windows側で作成したファイルの実行権限: `chmod +x script.sh`
   - WSL内での所有者変更: `sudo chown $USER:$USER filename`

3. **WSLのファイルが見つからない**
   - WSLのリセット: `wsl --shutdown` の後に再起動
   - WSLディストリビューションの確認: `wsl --list`

## 7. おすすめのVS Code拡張機能

1. **Remote - WSL**: WSLとの連携に必須
2. **Docker**: コンテナの管理や開発に便利
3. **ESLint/Prettier**: コード整形とリンティング
4. **GitLens**: Git履歴の可視化
5. **WSL**: Bash言語サポート

---

## まとめ: お勧めのセットアップ方法

本プロジェクト（ManageMediaServer）の場合、以下の方法が最も効率的です：

1. **Windows側に既存リポジトリがある場合**:
   ```bash
   # WSLターミナルを開く
   wsl
   
   # プロジェクトディレクトリに移動
   cd /mnt/d/ManageMediaServer
   
   # VS CodeをWSLモードで開く
   code .
   ```

2. **VS Code内から**:
   - 統合ターミナルが自動的にWSLターミナルになる
   - スクリプトに実行権限を付与: `chmod +x scripts/install/*.sh`
   - スクリプトを実行: `sudo ./scripts/install/install-docker.sh`

この方法により、Windows側のファイルを編集しながら、WSL環境でLinuxコマンドを実行できます。
