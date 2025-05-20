# DockerをインストールするためのPowerShellスクリプト

# Dockerのインストールを確認
if (-Not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "Dockerがインストールされていません。インストールを開始します..."

    # Dockerのインストール用URL
    $dockerUrl = "https://desktop.docker.com/win/stable/Docker%20Desktop%20Installer.exe"
    $installerPath = "$env:TEMP\DockerInstaller.exe"

    # Dockerインストーラーをダウンロード
    Invoke-WebRequest -Uri $dockerUrl -OutFile $installerPath

    # インストーラーを実行
    Start-Process -FilePath $installerPath -ArgumentList "install" -Wait

    # インストール後、Dockerを起動
    Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"

    Write-Host "Dockerのインストールが完了しました。"
} else {
    Write-Host "Dockerはすでにインストールされています。"
}