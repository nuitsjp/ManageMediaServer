#!/usr/bin/env pwsh
#Requires -RunAsAdministrator

if (![System.Diagnostics.EventLog]::SourceExists("BackupOneDrive")) {
    New-EventLog -LogName Application -Source "BackupOneDrive"
    Write-Host "イベントソース BackupOneDrive を作成しました。"
} else {
    Write-Host "イベントソース BackupOneDrive は既に存在します。"
}
