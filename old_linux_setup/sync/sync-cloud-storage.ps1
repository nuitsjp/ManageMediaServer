# クラウドストレージと同期を行うPowerShellスクリプト

# rcloneの設定ファイルのパス
$rcloneConfigPath = "config/rclone/rclone.conf"

# 同期するクラウドストレージのリモート名
$remoteName = "myremote"  # ここを適切なリモート名に変更してください

# 同期するローカルディレクトリのパス
$localDirectory = "path\to\local\directory"  # ここを適切なローカルディレクトリに変更してください

# 同期コマンドの実行
rclone sync $remoteName:$localDirectory $localDirectory --config $rcloneConfigPath --progress

# 同期結果の確認
if ($LASTEXITCODE -eq 0) {
    Write-Host "クラウドストレージとの同期が成功しました。"
} else {
    Write-Host "クラウドストレージとの同期中にエラーが発生しました。"
}