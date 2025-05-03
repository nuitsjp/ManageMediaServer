# 動画ファイルの拡張子リスト
$videoExtensions = @(".mp4", ".avi", ".mov", ".mkv", ".wmv", ".flv")

# カレントディレクトリ内の全てのファイルを処理
Get-ChildItem -File | ForEach-Object {
    # ファイルが動画ファイルかチェック
    if ($videoExtensions -contains $_.Extension.ToLower()) {
        try {
            # Shell.Applicationオブジェクトを使用してファイルのプロパティを取得
            $shell = New-Object -ComObject Shell.Application
            $folder = $shell.Namespace($_.DirectoryName)
            $file = $folder.ParseName($_.Name)
            
            # メディア作成日時を取得（インデックス208がメディア作成日時）
            $mediaCreatedDate = $folder.GetDetailsOf($file, 208)
            
            Write-Host "Raw date string: '$mediaCreatedDate'"

            # 日付文字列をクリーンアップ（年/月/日のみを抽出）
            $mediaCreatedDate = $mediaCreatedDate -replace '[^\d/]', ''
            if ($mediaCreatedDate -match '(\d{4}/\d{1,2}/\d{1,2})') {
                $mediaCreatedDate = $matches[1]
            }

            Write-Host "Cleaned date string: '$mediaCreatedDate'"

            if ([string]::IsNullOrEmpty($mediaCreatedDate)) {
                $year = $_.CreationTime.Year
                Write-Host "Using file creation year: $year"
            } else {
                # "yyyy/M/d" 形式の日付から年を抽出
                try {
                    $year = [datetime]::ParseExact($mediaCreatedDate, "yyyy/M/d", [System.Globalization.CultureInfo]::InvariantCulture).Year
                    Write-Host "Extracted year: $year"
                } catch {
                    Write-Host "Date parsing failed. Using file creation year."
                    $year = $_.CreationTime.Year
                }
            }
            
            # 年のサブフォルダを作成（既に存在する場合は作成しない）
            $targetFolder = Join-Path -Path $_.DirectoryName -ChildPath $year
            if (!(Test-Path $targetFolder)) {
                New-Item -Path $targetFolder -ItemType Directory | Out-Null
            }
            
            # ファイルを年のサブフォルダに移動
            Move-Item -Path $_.FullName -Destination $targetFolder -Force
            Write-Host "Moved $($_.Name) to $targetFolder"
        }
        catch {
            Write-Host "Error processing $($_.Name): $_"
        }
    }
}

Write-Host "処理が完了しました。"