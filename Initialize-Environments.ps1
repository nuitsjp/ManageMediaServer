#!/usr/bin/env pwsh
# Windowsイベントログのイベントソースに「BackupOneDrive」が存在しなければ作成する
# 実行には管理者権限が必要

# 管理者権限チェック
if (-not ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "管理者権限で実行してください。"
    exit 1
}

if (![System.Diagnostics.EventLog]::SourceExists("BackupOneDrive")) {
    New-EventLog -LogName Application -Source "BackupOneDrive"
    Write-Host "イベントソース BackupOneDrive を作成しました。"
} else {
    Write-Host "イベントソース BackupOneDrive は既に存在します。"
}
