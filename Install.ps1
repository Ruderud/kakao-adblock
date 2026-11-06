$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot 'runtime'
$null = New-Item -ItemType Directory -Path $root -Force
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$stagedLauncher = Join-Path $root 'KakaoAdMaintenance.new.exe'
& $compiler /nologo /target:winexe /optimize+ ('/out:' + $stagedLauncher) (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
$installedScript = Join-Path $root 'Maintenance.ps1'
if (Test-Path -LiteralPath $installedScript) {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installedScript -Mode Stop
    # Only terminate the exact previously recorded supervisor after verifying its command line.
    $statusPath = Join-Path $root 'status.json'
    foreach ($candidate in @($statusPath, ($statusPath + '.bak'))) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $status = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
            if ($status.SupervisorPid) {
                $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$status.SupervisorPid)
                if ($process.Name -eq 'powershell.exe' -and $process.CommandLine.Contains(('"' + $installedScript + '" -Mode Watch'))) {
                    Stop-Process -Id $status.SupervisorPid -Force
                }
            }
        } catch {}
    }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Maintenance.ps1') -Destination $root -Force
$launcher = Join-Path $root 'KakaoAdMaintenance.exe'
Move-Item -LiteralPath $stagedLauncher -Destination $launcher -Force
if (Test-Path -LiteralPath (Join-Path $root 'disabled')) { Remove-Item -LiteralPath (Join-Path $root 'disabled') }
$null = New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Force
$null = New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'KakaoTalkAdMaintenance' -Value ('"' + $launcher + '"') -PropertyType String -Force
# Use a non-virtualized project path: packaged Codex redirects LocalAppData writes.
# Logon plus a repeating task also recovers a stopped supervisor.
try {
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $installedScript + '" -Mode Watch'
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
    $trigger = @(
        (New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5))
    )
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
    $null = Register-ScheduledTask -TaskName 'KakaoTalkAdMaintenance' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
    'Watchdog task registered.'
} catch { Write-Warning ('Scheduled watchdog unavailable; sign-in startup is installed. ' + $_.Exception.Message) }
Start-Process -FilePath $launcher -WindowStyle Hidden
'Installed: ' + $root
