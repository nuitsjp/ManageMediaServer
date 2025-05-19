. $PSScriptRoot\Common.ps1
. $PSScriptRoot\WSL.ps1

function Test-ImmichComposeFileExists {
    [CmdletBinding()]
    param()
    Write-Log "/opt/immich/docker-compose.yml の存在を確認します..."
    wsl -d $script:DistroName -- test -f /opt/immich/docker-compose.yml
    if ($LASTEXITCODE -eq 0) {
        Write-Log "/opt/immich/docker-compose.yml が存在します。" -Level 'VERBOSE'
        return $true
    } else {
        Write-Log "/opt/immich/docker-compose.yml が存在しません。" -Level 'VERBOSE'
        return $false
    }
}

function Read-ImmichExternalLibraryPath {
    [CmdletBinding()]
    param(
        [string]$Prompt = "Immichの外部ライブラリーパスを入力してください"
    )
    while ($true) {
        $inputPath = Read-Host -Prompt $Prompt
        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            Write-Log "パスが空です。再度入力してください。" -Level 'WARN'
            continue
        }
        if (Test-Path $inputPath) {
            Write-Log "パスが存在します: $inputPath" -Level 'INFO'
            # WSLパスに変換して返却
            $wslPath = Convert-WindowsPathToWSLPath -WindowsPath $inputPath
            Write-Log "変換後のWSLパス: $wslPath" -Level 'INFO'
            return $wslPath
        } else {
            Write-Log "指定されたパスが存在しません: $inputPath" -Level 'WARN'
        }
    }
}
