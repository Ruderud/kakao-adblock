$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot 'runtime'
$task = Get-ScheduledTask -TaskName 'KakaoTalkAdMaintenance' -ErrorAction SilentlyContinue
if ($task) { Unregister-ScheduledTask -TaskName 'KakaoTalkAdMaintenance' -Confirm:$false }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'KakaoTalkAdMaintenance' -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath (Join-Path $root 'Maintenance.ps1')) {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Maintenance.ps1') -Mode Stop
}
'Startup and watchdog removed; protection disabled. Files and existing hosts entries retained.'
'Restart KakaoTalk manually to restore any current window layout changes.'
