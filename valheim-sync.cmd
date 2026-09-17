@echo off
rem Runs valheim-sync.ps1 without needing to change the PowerShell execution policy.
rem Usage: valheim-sync pull ^| push ^| play ^| status  [-Force]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0valheim-sync.ps1" %*
