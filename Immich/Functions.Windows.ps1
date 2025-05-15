# 共通のログ関数
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    
    switch ($Level) {
        'INFO'  { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error $Message }
    }
}