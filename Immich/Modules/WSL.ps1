. $PSScriptRoot\Common.ps1

function Test-WSLUserExists {
    [CmdletBinding()]
    param ()
    Write-Log "WSLディストリビューション '$script:DistroName' にユーザー '$script:WSLUserName' の存在確認を開始します。" -Level "INFO"
    $result = wsl -d $script:DistroName getent passwd $script:WSLUserName 2>$null
    if (-not [string]::IsNullOrEmpty($result)) {
        Write-Log "ユーザー '$script:WSLUserName' は存在します。" -Level "INFO"
        return $true
    } else {
        Write-Log "ユーザー '$script:WSLUserName' は存在しません。" -Level "INFO"
        return $false
    }
}

function Convert-WindowsPathToWSLPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath
    )
    # WindowsパスをWSLパスに変換
    $escapedPath = $WindowsPath.Replace('\', '\\')
    $cmd = "wsl -d $script:DistroName -- wslpath '$escapedPath'"
    $wslPath = (Invoke-Expression $cmd).Trim().Replace('"', '')
    Write-Log "Windowsパス: $WindowsPath" -Level 'VERBOSE'
    Write-Log "WSLパス: $wslPath" -Level 'VERBOSE'
    return $wslPath
}

function Invoke-WSLCopyAndRunScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptFileName,
        [string[]]$Arguments = @()
    )
    # WSL内でスクリプトをコピー・変換・実行
    $ScriptPathOnWindows = Join-Path -Path $PSScriptRoot -ChildPath $ScriptFileName
    if (-not (Test-Path $ScriptPathOnWindows)) {
        throw "$ScriptPathOnWindows が見つかりません。PowerShellスクリプトと同じディレクトリに配置してください。"
    }
    $SourcePathOnWSL = Convert-WindowsPathToWSLPath -WindowsPath $ScriptPathOnWindows
    if ([string]::IsNullOrEmpty($SourcePathOnWSL)) {
        throw "WSLパスの変換結果が空です"
    }
    $DestinationScriptNameOnWSL = "setup_immich_for_distro.sh"
    $DestinationPathOnWSL = "/tmp/$DestinationScriptNameOnWSL"
    $ArgString = ($Arguments | ForEach-Object { "'$_'" }) -join " "
    $WslCommands = @"
cp '$SourcePathOnWSL' '$DestinationPathOnWSL' && \
dos2unix '$DestinationPathOnWSL' && \
chmod +x '$DestinationPathOnWSL' && \
sudo '$DestinationPathOnWSL' $ArgString
"@ -replace "`r",""
    Write-Log "WSL内で以下のコマンドを実行します:" -Level "VERBOSE"
    Write-Log $WslCommands -Level "VERBOSE"
    wsl -d $script:DistroName -- bash -c "$WslCommands"
    if ($LASTEXITCODE -ne 0) {
        throw "WSL内でのスクリプト実行に失敗しました (終了コード: $LASTEXITCODE)"
    }
    Write-Log "WSL内セットアップスクリプトの実行が完了しました。" -Level "INFO"
}
