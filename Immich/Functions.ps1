# 環境変数取得用関数定義
function Get-OrSet-Env {
    param(
        [string]$EnvName,
        [string]$PromptName,
        [string]$DefaultValue,
        [switch]$NoPrompt = $false
    )
    
    # まずマシンレベルで環境変数を取得を試みる
    try {
        $val = [Environment]::GetEnvironmentVariable($EnvName, 'Machine')
    } catch {
        # 管理者権限がない場合はユーザーレベルを試みる
        $val = [Environment]::GetEnvironmentVariable($EnvName, 'User')
    }
    
    if (-not $val) {
        if ($NoPrompt) {
            $val = $DefaultValue
            Write-Host "${PromptName} を既定値で設定します: $val"
        } else {
            $ans = Read-Host "${PromptName} の既定値: $DefaultValue でよろしいですか？ [Y/N]"
            if ($ans -match '^[Nn]') {
                $val = Read-Host "${PromptName} を入力してください"
            } else {
                $val = $DefaultValue
            }
        }
        
        # 環境変数を設定（管理者権限がない場合はユーザーレベルで設定）
        try {
            [Environment]::SetEnvironmentVariable($EnvName, $val, 'Machine')
            Write-Host "${PromptName} をシステム環境変数に登録しました: $val"
        } catch {
            # 管理者権限がない場合
            [Environment]::SetEnvironmentVariable($EnvName, $val, 'User')
            Write-Host "${PromptName} をユーザー環境変数に登録しました: $val"
        }
    } else {
        Write-Host "${PromptName}: $val (環境変数から取得)"
    }
    
    return $val
}

# WindowsパスをWSLパスに変換する関数
function ConvertTo-WslPath {
    param(
        [string]$WindowsPath,
        [string]$DistributionName = "Ubuntu"
    )
    
    # パスの正規化（バックスラッシュをスラッシュに変換、ドライブレターを変換）
    $normalized = $WindowsPath.Replace('\', '/')
    if ($normalized -match '^([A-Za-z]):(.*)$') {
        $driveLetter = $matches[1].ToLower()
        $remainingPath = $matches[2]
        $wslPath = "/mnt/$driveLetter$remainingPath"
        
        Write-Host "Windows パス '$WindowsPath' は WSL パス '$wslPath' に変換されました"
        return $wslPath
    } else {
        Write-Error "正しいWindowsパス形式ではありません: $WindowsPath"
        return $null
    }
}

# WSL内のディレクトリが存在するか確認し、存在しなければ作成する関数
function Ensure-WslDirectory {
    param(
        [string]$WslPath,
        [string]$DistributionName = "Ubuntu"
    )

    # ディレクトリの存在確認
    $checkDir = & wsl -d $DistributionName -- bash -c "test -d '$WslPath' && echo 'exists' || echo 'not exists'"
    
    if ($checkDir -eq "not exists") {
        Write-Host "WSL内のディレクトリ '$WslPath' を作成します..."
        & wsl -d $DistributionName -- mkdir -p "$WslPath"
        if ($LASTEXITCODE -ne 0) {
            Write-Error "ディレクトリの作成に失敗しました: $WslPath"
            return $false
        }
        Write-Host "ディレクトリを作成しました: $WslPath"
    } else {
        Write-Host "WSL内のディレクトリは既に存在します: $WslPath"
    }
    
    return $true
}
