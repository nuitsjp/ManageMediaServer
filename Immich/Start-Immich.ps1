#!/usr/bin/env pwsh
# 管理者権限を推奨

# Windows 11のWSL上にDockerを構築し、そこにImmichをコンテナーとして導入します。
# Immichが未導入の場合は導入してから起動します。
# 前提としてWSLは導入済みだが、Linuxディストリビューションは未導入の状態であること。
# また、Immichの導入にはDockerが必要なので、WSL上にDockerを導入します。
# さらに、Immichの導入にはPostgreSQLとRedisが必要なので、これらもDockerコンテナーとして導入します。
# WSLディストリビューションの確認と導入

$ErrorActionPreference = 'Stop'

$distributionName = "Ubuntu"

# WSLの確認と導入
Write-Host "WSLのディストリビューション「$distributionName」を確認しています..."
$wslList = (wsl --list)
if ($wslList -match $distributionName) {
    Write-Host "WSLディストリビューション「$distributionName」は既に導入されています。"
} else {
    Write-Host "WSLディストリビューション「$distributionName」を導入します..."
    & wsl --install -d $distributionName
    if ($LASTEXITCODE -ne 0) {
        Write-Error "WSLディストリビューション「$distributionName」の導入に失敗しました。"
        exit 1
    }
    Write-Host "WSLディストリビューション「$distributionName」の導入が完了しました。"
}

# Dockerの確認と導入 (WSL内)
Write-Host "Dockerの導入状況を確認しています..."
# Dockerの確認
& wsl -d $distributionName -- docker --version >$null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Dockerが検出されませんでした。WSL上にDockerをインストールします..."
    & wsl -d $distributionName -- sudo apt update
    & wsl -d $distributionName -- sudo apt install -y docker.io
    & wsl -d $distributionName -- sudo service docker start
    # Dockerグループの追加（sudo不要で実行できるようにする）
    $currentUser = & wsl -d $distributionName -- whoami
    & wsl -d $distributionName -- sudo usermod -aG docker $currentUser
    Write-Host "Dockerのインストールと起動が完了しました。"
    Write-Host "注意: Docker権限を反映するには、WSLセッションの再起動が必要な場合があります。"
} else {
    Write-Host "Dockerは既にインストールされています。"    # Dockerサービスが起動しているか確認して、起動していなければ開始
    $dockerRunning = & wsl -d $distributionName -- bash -c "service docker status | grep 'Active: active' || echo ''"
    if (-not $dockerRunning) {
        Write-Host "Dockerサービスを起動しています..."
        & wsl -d $distributionName -- sudo service docker start
    }
    
    # Dockerグループの確認と追加
    $currentUser = & wsl -d $distributionName -- whoami
    $inDockerGroup = & wsl -d $distributionName -- bash -c "groups | grep docker || echo ''"
    if (-not $inDockerGroup) {
        Write-Host "ユーザー $currentUser をdockerグループに追加します..."
        & wsl -d $distributionName -- sudo usermod -aG docker $currentUser
        Write-Host "ユーザーをdockerグループに追加しました。WSLセッションを再起動してください。"
        & wsl -d $distributionName -- sudo newgrp docker
    }
      # Dockerソケットの権限確認と修正
    $socketPermissions = & wsl -d $distributionName -- bash -c "ls -la /var/run/docker.sock | awk '{print \$1}'"
    if ($socketPermissions -notmatch "^srw-rw") {
        Write-Host "Dockerソケットの権限を修正します..."
        & wsl -d $distributionName -- sudo chmod 666 /var/run/docker.sock
    }
}
# Dockerバージョンの表示
$dockerVersion = & wsl -d $distributionName -- docker --version
Write-Host "Dockerバージョン: $dockerVersion"

# Docker Composeの確認と導入
Write-Host "Docker Composeの導入状況を確認しています..."
# 新しい 'docker compose' 形式を確認
& wsl -d $distributionName -- docker compose version >$null 2>&1
$useNewCompose = $LASTEXITCODE -eq 0

if (-not $useNewCompose) {
    # 古い 'docker-compose' コマンドを確認
    & wsl -d $distributionName -- docker-compose --version >$null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Docker Composeが検出されませんでした。WSL上にDocker Composeをインストールします..."
        & wsl -d $distributionName -- sudo apt update
        & wsl -d $distributionName -- sudo apt install -y docker-compose
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Docker Composeのインストールに失敗しました。"
            exit 1
        }
        Write-Host "Docker Composeのインストールが完了しました。"
        $composeCommand = "docker-compose"
    } else {
        Write-Host "Docker Compose（従来版）は既にインストールされています。"
        $composeVersion = & wsl -d $distributionName -- docker-compose --version
        Write-Host "Docker Composeバージョン: $composeVersion"
        $composeCommand = "docker-compose"
    }
} else {
    Write-Host "Docker Compose（新版）は既にインストールされています。"
    $composeVersion = & wsl -d $distributionName -- docker compose version
    Write-Host "Docker Composeバージョン: $composeVersion"
    $composeCommand = "docker compose"
}

# Functionsファイルの読み込み
. $PSScriptRoot\Functions.ps1

# アップロード先とDBデータ保存先を共通関数で設定
$uploadLocation    = Get-OrSet-Env -EnvName 'IMMICH_UPLOAD_LOCATION'    -PromptName '画像アップロードパス'    -DefaultValue 'C:\immich-photos' -NoPrompt
$dbDataLocation    = Get-OrSet-Env -EnvName 'IMMICH_DB_DATA_LOCATION'   -PromptName 'postgresデータベースパス' -DefaultValue 'C:\immich-postgres' -NoPrompt

# uploadsディレクトリの確認と作成
if (-not (Test-Path $uploadLocation)) {
    Write-Host "画像アップロードディレクトリを作成します: $uploadLocation"
    New-Item -ItemType Directory -Path $uploadLocation -Force | Out-Null
}

# DBデータディレクトリの確認と作成
if (-not (Test-Path $dbDataLocation)) {
    Write-Host "PostgreSQLデータディレクトリを作成します: $dbDataLocation"
    New-Item -ItemType Directory -Path $dbDataLocation -Force | Out-Null
}

# WSL内でのパス
$wslUploadPath = ConvertTo-WslPath -WindowsPath $uploadLocation -DistributionName $distributionName
$wslDbDataPath = ConvertTo-WslPath -WindowsPath $dbDataLocation -DistributionName $distributionName

# WSL内でディレクトリを確認・作成
Ensure-WslDirectory -WslPath $wslUploadPath -DistributionName $distributionName
Ensure-WslDirectory -WslPath $wslDbDataPath -DistributionName $distributionName
 
# データベースディレクトリの権限を設定
Write-Host "PostgreSQLデータディレクトリの権限を設定します..."
& wsl -d $distributionName -- sudo chown -R 999:999 $wslDbDataPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "警告: PostgreSQLデータディレクトリの権限設定に失敗しました。必要な場合は管理者権限で実行してください。"
}

# downloadsフォルダ作成とファイル取得
$downloadsDir = Join-Path $PSScriptRoot 'downloads'
if (-not (Test-Path $downloadsDir)) {
    Write-Host "downloadsフォルダを作成します: $downloadsDir"
    New-Item -ItemType Directory -Path $downloadsDir | Out-Null
} else {
    Write-Host "downloadsフォルダは既に存在します: $downloadsDir"
}
$files = @{
    'https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml' = 'docker-compose.yml'
    'https://github.com/immich-app/immich/releases/latest/download/example.env'        = 'example.env'
}
foreach ($url in $files.Keys) {
    $dest = Join-Path $downloadsDir $files[$url]
    if (-not (Test-Path $dest)) {
        Write-Host "ダウンロード中: $($files[$url])"
        Invoke-WebRequest -Uri $url -OutFile $dest
    } else {
        Write-Host "既に存在するためスキップ: $($files[$url])"
    }
}

# 実行ディレクトリを作成
$immichDir = Join-Path $PSScriptRoot 'instance'
if (-not (Test-Path $immichDir)) {
    Write-Host "Immich実行ディレクトリを作成します: $immichDir"
    New-Item -ItemType Directory -Path $immichDir -Force | Out-Null
} else {
    Write-Host "Immich実行ディレクトリは既に存在します: $immichDir"
}

# 必要なファイルをインスタンスディレクトリにコピー
$composeFile = Join-Path $immichDir 'docker-compose.yml'
if (-not (Test-Path $composeFile)) {
    # docker-compose.ymlの内容を修正して古いバージョンとの互換性を確保
    $composeContent = Get-Content (Join-Path $downloadsDir 'docker-compose.yml') -Raw
    
    # 古いバージョンのdocker-composeでは'name'プロパティがサポートされていないため削除
    $composeContent = $composeContent -replace '(?m)^name: immich\s*$', ''
    
    # healthcheckのstart_intervalプロパティは古いバージョンのdocker-composeでサポートされていないため削除
    $composeContent = $composeContent -replace 'start_interval: \d+s\s*', ''
    
    # 修正したdocker-compose.ymlをインスタンスディレクトリに書き込み
    $composeContent | Set-Content -Path $composeFile -Encoding UTF8
    Write-Host "docker-compose.yml を修正してコピーしました"
} else {
    Write-Host "docker-compose.yml は既に存在します"
}

# .envファイルの作成
$envFile = Join-Path $immichDir '.env'
if (-not (Test-Path $envFile)) {
    # example.envを読み込んで必要な変更を加える
    $envContent = Get-Content (Join-Path $downloadsDir 'example.env') -Raw

    # 環境変数の設定
    $envContent = $envContent -replace '(?m)^UPLOAD_LOCATION=.*$', "UPLOAD_LOCATION=$wslUploadPath"
    $envContent = $envContent -replace '(?m)^DB_DATA_LOCATION=.*$', "DB_DATA_LOCATION=$wslDbDataPath"
    
    # ランダムなデータベースパスワードを生成
    $dbPassword = -join ((65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    $envContent = $envContent -replace '(?m)^DB_PASSWORD=.*$', "DB_PASSWORD=$dbPassword"
      # タイムゾーンの設定
    $timeZone = Get-OrSet-Env -EnvName 'IMMICH_TIMEZONE' -PromptName 'タイムゾーン' -DefaultValue 'Asia/Tokyo' -NoPrompt
    $envContent = $envContent -replace '(?m)^# TZ=.*$', "TZ=$timeZone"

    # .envファイルに書き込み
    $envContent | Set-Content -Path $envFile -Encoding UTF8
    Write-Host ".env ファイルを作成しました"
} else {
    # 既存の.envファイルを読み込み、パスを更新
    Write-Host "既存の.envファイルを更新します..."
    $envContent = Get-Content $envFile -Raw
    
    # パスをWSLパスに変換
    $envContent = $envContent -replace '(?m)^UPLOAD_LOCATION=.*$', "UPLOAD_LOCATION=$wslUploadPath"
    $envContent = $envContent -replace '(?m)^DB_DATA_LOCATION=.*$', "DB_DATA_LOCATION=$wslDbDataPath"
    
    # 更新した内容を書き込み
    $envContent | Set-Content -Path $envFile -Encoding UTF8
    Write-Host ".env ファイルを更新しました"
}

# WSL内のパスを取得
$wslImmichDir = ConvertTo-WslPath -WindowsPath $immichDir -DistributionName $distributionName

# WSLセッションを一度再起動して、ユーザーグループの変更を確実に反映
Write-Host "WSLセッションを再起動して権限変更を反映します..."
& wsl --terminate $distributionName
Start-Sleep -Seconds 2
& wsl -d $distributionName -- echo "WSLセッションを再起動しました"

# Docker内部のネットワーク名前解決を確保するために、hostsファイルにエントリを追加
Write-Host "Docker内部のネットワーク名前解決を設定しています..."
$wslEtcHosts = & wsl -d $distributionName -- bash -c "grep -q 'immich_postgres' /etc/hosts && echo 'exists' || echo 'not exists'"
if ($wslEtcHosts -eq "not exists") {
    & wsl -d $distributionName -- sudo bash -c "echo '127.0.0.1 database' >> /etc/hosts"
    & wsl -d $distributionName -- sudo bash -c "echo '127.0.0.1 immich_postgres' >> /etc/hosts"
    Write-Host "hostsファイルを更新しました"
} else {
    Write-Host "hostsファイルは既に設定されています"
}

# WSL2のIPアドレスを取得し、Windowsのホストファイルに追加（必要な場合）
$wslIp = & wsl -d $distributionName -- hostname -I | ForEach-Object { $_.Trim() }
Write-Host "WSL2のIPアドレス: $wslIp"

# Immichサービスの起動
Write-Host "Immichサービスを起動します..."
& wsl -d $distributionName -- bash -c "cd '$wslImmichDir' && $composeCommand up -d"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Immichサービスの起動に失敗しました。"
    exit 1
}

# WSL2からWindowsホストへのポートフォワーディングを確認
Write-Host "WSL2からWindowsホストへのポートフォワーディングを設定しています..."
$wslIp = & wsl -d $distributionName -- hostname -I | ForEach-Object { $_.Trim() }
if ($wslIp) {
    # ポートプロキシの設定を確認
    $netshOutput = netsh interface portproxy show v4tov4 | Select-String "2283"
    if (-not $netshOutput) {
        # 管理者権限が必要なため、警告のみ表示
        Write-Host "以下のコマンドを管理者権限で実行すると、ポートフォワーディングを設定できます:"
        Write-Host "netsh interface portproxy add v4tov4 listenport=2283 listenaddress=0.0.0.0 connectport=2283 connectaddress=$wslIp"
    } else {
        Write-Host "ポートフォワーディングは既に設定されています"
    }
}

# 起動確認
Write-Host "Immichの起動状態を確認しています..."
Start-Sleep -Seconds 10  # サービス起動のための待機時間

$containers = & wsl -d $distributionName -- bash -c "cd '$wslImmichDir' && $composeCommand ps --services"
Write-Host "実行中のコンテナ:"
$containers | ForEach-Object { Write-Host "- $_" }

Write-Host "Immichは正常に起動しました。以下のURLでアクセスできます："
Write-Host "http://localhost:2283"
Write-Host "初回アクセス時は管理者アカウントの作成が必要です。"
Write-Host ""
Write-Host "停止するには以下のコマンドを実行してください："
Write-Host "wsl -d $distributionName -- bash -c ""cd '$wslImmichDir' && $composeCommand down"""
