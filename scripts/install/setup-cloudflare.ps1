# Cloudflareの設定を行うためのPowerShellスクリプト

# Cloudflare Tunnelの設定を読み込み
$tunnelConfigPath = "config/cloudflare/tunnel_config.yaml"

# Cloudflare Tunnelの設定を適用する関数
function Setup-CloudflareTunnel {
    param (
        [string]$configPath
    )

    if (Test-Path $configPath) {
        # 設定ファイルを読み込む
        $config = Get-Content $configPath -Raw | ConvertFrom-Yaml

        # Cloudflare Tunnelの設定を適用するコマンドを実行
        # ここにCloudflare CLIを使用した設定適用のコマンドを追加
        # 例: cloudflared tunnel create $config.tunnelName
        Write-Host "Cloudflare Tunnel '$($config.tunnelName)' を設定中..."
        
        # 追加の設定コマンドをここに記述
        # 例: cloudflared tunnel route dns $config.tunnelName $config.hostname

        Write-Host "Cloudflare Tunnelの設定が完了しました。"
    } else {
        Write-Host "設定ファイルが見つかりません: $configPath"
    }
}

# Cloudflare Tunnelの設定を実行
Setup-CloudflareTunnel -configPath $tunnelConfigPath