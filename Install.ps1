$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot 'runtime'
$null = New-Item -ItemType Directory -Path $root -Force
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$stagedLauncher = Join-Path $root 'KakaoAdMaintenance.new.exe'
& $compiler /nologo /target:winexe /optimize+ ('/out:' + $stagedLauncher) (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
$stagedDiagnostics = Join-Path $root 'Diagnostics.new.dll'
& $compiler /nologo /target:library /optimize+ /codepage:65001 /reference:System.Web.Extensions.dll ('/out:' + $stagedDiagnostics) (Join-Path $PSScriptRoot 'Diagnostics.cs')
if ($LASTEXITCODE -ne 0) { throw 'Diagnostics compilation failed; existing protection unchanged.' }
$installedScript = Join-Path $root 'Maintenance.ps1'
$launcher = Join-Path $root 'KakaoAdMaintenance.exe'
$previous = Join-Path $root 'install-previous'
$null = New-Item -ItemType Directory -Path $previous -Force
$previousFiles = @{}
foreach ($name in @('Diagnostics.dll','Maintenance.ps1','KakaoAdMaintenance.exe')) {
    $path = Join-Path $root $name
    if (Test-Path -LiteralPath $path) {
        Copy-Item -LiteralPath $path -Destination (Join-Path $previous $name) -Force
        $previousFiles[$name] = $true
    }
}
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
                    $ownedSupervisor = Get-Process -Id $status.SupervisorPid -ErrorAction SilentlyContinue
                    Stop-Process -Id $status.SupervisorPid -Force
                    if ($ownedSupervisor -and -not $ownedSupervisor.WaitForExit(10000)) { throw 'Previous supervisor did not exit.' }
                }
            }
        } catch {}
    }
}
$promoted = @()
try {
    Move-Item -LiteralPath $stagedDiagnostics -Destination (Join-Path $root 'Diagnostics.dll') -Force
    $promoted += 'Diagnostics.dll'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Maintenance.ps1') -Destination $root -Force
    $promoted += 'Maintenance.ps1'
    Move-Item -LiteralPath $stagedLauncher -Destination $launcher -Force
    $promoted += 'KakaoAdMaintenance.exe'
} catch {
    $deploymentError = $_
    [array]::Reverse($promoted)
    foreach ($name in $promoted) {
        if ($previousFiles.ContainsKey($name)) { Copy-Item -LiteralPath (Join-Path $previous $name) -Destination (Join-Path $root $name) -Force }
        else { Remove-Item -LiteralPath (Join-Path $root $name) -Force }
    }
    if (Test-Path -LiteralPath (Join-Path $root 'disabled')) { Remove-Item -LiteralPath (Join-Path $root 'disabled') }
    if ($previousFiles.ContainsKey('KakaoAdMaintenance.exe')) { Start-Process -FilePath $launcher -WindowStyle Hidden }
    throw $deploymentError
}
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
