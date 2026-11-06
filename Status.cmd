@echo off
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0runtime\Maintenance.ps1" -Mode Status
pause
