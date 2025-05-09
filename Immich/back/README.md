# Immich

Windows 11のWSL上にDockerを構築し、そこにImmichをコンテナーとして導入します。

## 前提環境

1.  Windows 11 Home
2.  WSL2
3.  Ubuntu (WSL内)

## 導入・運用手順概要

本ドキュメントで説明する手順および提供するスクリプト ([`Start-Immich.ps1`](Immich/Start-Immich.ps1), [`Stop-Immich.ps1`](Immich/Stop-Immich.ps1)) は、冪等性を考慮して作成されています。既に環境が構築済みの場合、[`Start-Immich.ps1`](Immich/Start-Immich.ps1) は既存のImmichコンテナを停止し、イメージを最新版に更新してから再度起動します。

### 1. WSLおよびUbuntuの導入

1.  **WSLの有効化:**
    *   管理者権限でPowerShellを開き、以下のコマンドを実行します。
        ```powershell
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
        ```
    *   PCを再起動します。
2.  **Linuxカーネル更新プログラムパッケージのインストール:**
    *   [x64 マシン用 WSL2 Linux カーネル更新プログラム パッケージ](https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi) をダウンロードしてインストールします。
3.  **WSL 2 を既定のバージョンとして設定:**
    *   PowerShellで以下のコマンドを実行します。
        ```powershell
        wsl --set-default-version 2
        ```
4.  **Ubuntuのインストール:**
    *   Microsoft Storeから「Ubuntu」を検索し、インストールします（特定のバージョンがあればそれを選択）。
5.  **Ubuntuの初期設定:**
    *   インストール後、Ubuntuを起動し、指示に従ってユーザー名とパスワードを設定します。

### 2. Dockerの導入 (Ubuntu内)

Ubuntuターミナル（WSL内）で以下のコマンドを実行します。

1.  **システムパッケージの更新:**
    ```bash
    sudo apt-get update
    sudo apt-get upgrade -y
    ```
2.  **Dockerのインストールに必要なパッケージのインストール:**
    ```bash
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
    ```
3.  **Dockerの公式GPGキーを追加:**
    ```bash
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    ```
4.  **Dockerリポジトリを設定:**
    ```bash
    echo \
