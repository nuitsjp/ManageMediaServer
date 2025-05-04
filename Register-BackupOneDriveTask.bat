@echo off
REM Backup-OneDrive.ps1 を毎日AM6時に実行するタスクを登録
 
REM 既存タスクがあれば削除
schtasks /Delete /TN "Backup-OneDrive" /F >nul 2>&1

schtasks /Create ^
  /TN "Backup-OneDrive" ^
  /TR "pwsh.exe -ExecutionPolicy Bypass -File \"c:\Repos\BackupOneDrive\Backup-OneDrive.ps1\" -VideosDirectory \"C:\Users\atsus\Videos\" -BackupDirectory \"D:\Backup\"" ^
  /SC DAILY ^
  /ST 06:00 ^
  /RU "SYSTEM" ^
  /F

echo タスク登録が完了しました。