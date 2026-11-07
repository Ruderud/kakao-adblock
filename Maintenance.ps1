param(
    [ValidateSet('Watch','Once','Status','History','Repair','Stop','Resume','Library')]
    [string]$Mode = 'Watch'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Root = $PSScriptRoot
$script:StatePath = Join-Path $script:Root 'state.json'
$script:StatusPath = Join-Path $script:Root 'status.json'
$script:DisablePath = Join-Path $script:Root 'disabled'
$script:RequestPath = Join-Path $script:Root 'repair.request'
$script:Session = (Get-Process -Id $PID).SessionId
$script:AssetName = 'KakaoTalkAdBlock_amd64.exe'
$script:LogPath = Join-Path $script:Root 'maintenance.log'

function Write-Log([string]$Message) {
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 1048576) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.previous') -Force
        }
        Add-Content -LiteralPath $script:LogPath -Value ((Get-Date).ToString('o') + ' ' + $Message) -Encoding UTF8
    } catch { } # Logging must never terminate ad protection.
}
function Write-JsonAtomic([string]$Path, $Value) {
    $tmp = $Path + '.' + $PID + '.tmp'
    [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, ($Path + '.bak')) }
    else { [IO.File]::Move($tmp, $Path) }
}
function Read-State {
    foreach ($candidate in @($script:StatePath, ($script:StatePath + '.bak'))) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $state = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
            if (-not ($state.PSObject.Properties.Name -contains 'Current')) { continue }
            foreach ($name in @('Previous','LastCheckUtc','NextCheckUtc','RejectedVersion')) {
                if (-not ($state.PSObject.Properties.Name -contains $name)) {
                    $state | Add-Member -NotePropertyName $name -NotePropertyValue $null
                }
            }
            return $state
        } catch { Write-Log 'state-read-failed; trying backup' }
    }
    return [pscustomobject]@{Current=$null;Previous=$null;LastCheckUtc=$null;NextCheckUtc=$null;RejectedVersion=$null}
}
function Get-ReleaseSpec($Release) {
    if ($Release.draft -or $Release.prerelease -or $Release.tag_name -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
        throw 'Only stable numeric release tags are accepted.'
    }
    $assets = @($Release.assets | Where-Object { $_.name -ceq $script:AssetName })
    if ($assets.Count -ne 1) { throw 'Expected exactly one official amd64 asset.' }
    $asset = $assets[0]
    $expected = 'https://github.com/blurfx/KakaoTalkAdBlock/releases/download/' + $Release.tag_name + '/' + $script:AssetName
    if ($asset.browser_download_url -cne $expected) { throw 'Unexpected asset URL.' }
    if ($asset.digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Release is missing a SHA-256 digest.' }
    if ($asset.size -lt 100000 -or $asset.size -gt 52428800) { throw 'Unexpected asset size.' }
    return [pscustomobject]@{Version=[string]$Release.tag_name;Sha256=$asset.digest.Substring(7).ToLowerInvariant();Size=[long]$asset.size;Url=$expected}
}
function Get-BlockerPath($Record) {
    if ($null -eq $Record -or $Record.Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw 'Invalid installed version.' }
    return Join-Path $script:Root ('versions\' + $Record.Version + '\' + $script:AssetName)
}
function Test-Blocker($Record) {
    try {
        $path = Get-BlockerPath $Record
        return (Test-Path -LiteralPath $path) -and $Record.Sha256 -match '^[a-fA-F0-9]{64}$' -and
            ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ieq $Record.Sha256)
    } catch { return $false }
}
function Get-OwnedBlockers {
    $prefix = [IO.Path]::GetFullPath((Join-Path $script:Root 'versions')) + [IO.Path]::DirectorySeparatorChar
    foreach ($process in @(Get-Process -Name 'KakaoTalkAdBlock_amd64' -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -eq $script:Session -and $process.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $process
            }
        } catch {}
    }
}
function Stop-OwnedBlockers {
    foreach ($process in @(Get-OwnedBlockers)) {
        # Get-OwnedBlockers restricts both executable directory and session.
        $process.Kill()
        if (-not $process.WaitForExit(5000)) { throw 'Blocker did not stop.' }
    }
}
function Start-VerifiedBlocker($Record) {
    if (-not (Test-Blocker $Record)) { throw 'Installed blocker hash verification failed.' }
    $path = Get-BlockerPath $Record
    $process = Start-Process -FilePath $path -WorkingDirectory (Split-Path -Parent $path) -WindowStyle Hidden -PassThru
    if ($process.WaitForExit(3000)) { throw ('Blocker exited during startup: ' + $process.ExitCode) }
    Write-Log ('blocker-started version=' + $Record.Version + ' pid=' + $process.Id)
}
function Install-Latest($State) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/blurfx/KakaoTalkAdBlock/releases/latest' -Headers @{'User-Agent'='KakaoTalkAdMaintenance/1.0';'Accept'='application/vnd.github+json'} -TimeoutSec 20
    $spec = Get-ReleaseSpec $release
    if ($State.Current -and [version]$spec.Version -lt [version]$State.Current.Version) { throw 'Automatic downgrade refused.' }
    if ($State.RejectedVersion -eq $spec.Version) { throw 'This release previously failed; keeping the working version.' }
    if ($State.Current -and $State.Current.Version -eq $spec.Version -and (Test-Blocker $State.Current)) { return $false }
    $destination = Get-BlockerPath $spec
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
    $download = $destination + '.download'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $spec.Url -OutFile $download -TimeoutSec 60
        if ((Get-Item -LiteralPath $download).Length -ne $spec.Size -or (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ine $spec.Sha256) {
            throw 'Downloaded asset size/hash mismatch.'
        }
        $stream = [IO.File]::OpenRead($download)
        try { if ($stream.ReadByte() -ne 77 -or $stream.ReadByte() -ne 90) { throw 'Asset is not a Windows executable.' } }
        finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $script:DisablePath) { return $false }
        # Only verified bytes are promoted. Existing blocker remains running during download.
        if (Test-Path -LiteralPath $destination) { Stop-OwnedBlockers }
        Move-Item -LiteralPath $download -Destination $destination -Force
        $old = $State.Current
        Stop-OwnedBlockers
        try { Start-VerifiedBlocker $spec }
        catch {
            Stop-OwnedBlockers
            if ($old -and $old.Version -ne $spec.Version) { $State.RejectedVersion = $spec.Version }
            Write-JsonAtomic $script:StatePath $State
            if ($old -and (Test-Blocker $old)) {
                try { Start-VerifiedBlocker $old } catch { Write-Log ('rollback-start-failed ' + $_.Exception.Message) }
            }
            throw
        }
        if ($old -and $old.Version -ne $spec.Version) { $State.Previous = $old }
        $State.Current = $spec
        $State.RejectedVersion = $null
        Write-JsonAtomic $script:StatePath $State
        Write-Log ('release-installed version=' + $spec.Version + ' sha256=' + $spec.Sha256)
        return $true
    } finally {
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
    }
}
function Get-KakaoSnapshot {
    $items = @()
    foreach ($process in @(Get-Process -Name 'KakaoTalk','KakaoTalkUI' -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -ne $script:Session) { continue }
            $file = Get-Item -LiteralPath $process.Path
            $items += [pscustomobject]@{Pid=$process.Id;StartedUtc=$process.StartTime.ToUniversalTime().Ticks;Version=$file.VersionInfo.FileVersion;WriteTicks=$file.LastWriteTimeUtc.Ticks;Length=$file.Length}
        } catch { Write-Log ('kakao-inspection-failed pid=' + $process.Id) }
    }
    return @($items | Sort-Object Pid)
}
function Get-KakaoSignature($Items) { return (@($Items | ForEach-Object { '{0}:{1}:{2}:{3}:{4}' -f $_.Pid,$_.StartedUtc,$_.Version,$_.WriteTicks,$_.Length }) -join ';') }
function Get-CrashDelay([int]$Failures) { return [int][Math]::Min(300, (5 * [Math]::Pow(2, [Math]::Min(6, [Math]::Max(0, $Failures - 1))))) }
function Get-ReleaseSchedule($State, [datetime]$Now = [datetime]::UtcNow) {
    $Now = $Now.ToUniversalTime()
    $last = [datetime]::MinValue
    $next = [datetime]::MinValue
    try {
        if ($State.LastCheckUtc) { $last = [datetime]::Parse($State.LastCheckUtc).ToUniversalTime() }
        if ($State.NextCheckUtc) { $next = [datetime]::Parse($State.NextCheckUtc).ToUniversalTime() }
        # A clock correction must not postpone update checks for months or years.
        $reset = $last -gt $Now.AddMinutes(5) -or $next -gt $Now.AddHours(25) -or $next -lt $last
    } catch { $reset = $true }
    return [pscustomobject]@{
        ResetClock = $reset
        Due = $reset -or $next -eq [datetime]::MinValue -or $Now -ge $next
        ElapsedHours = $(if ($reset) { [double]::PositiveInfinity } else { ($Now - $last).TotalHours })
    }
}
function Get-HostsStatus([string]$Path = "$env:SystemRoot\System32\drivers\etc\hosts") {
    return @(Convert-HostsLines @(Get-Content -LiteralPath $Path))
}
function Convert-HostsLines([string[]]$Lines) {
    $required = @('display.ad.daum.net','adimg.daumcdn.net','adimg6.kakaocdn.net')
    $ipv4 = @{}; $ipv6 = @{}; $conflicts = @{}
    foreach ($line in $Lines) {
        $parts = ($line -replace '#.*$', '').Trim() -split '\s+'
        if ($parts.Count -lt 2) { continue }
        foreach ($domain in $parts[1..($parts.Count-1)]) {
            $domain = $domain.ToLowerInvariant()
            if ($parts[0] -in @('0.0.0.0','127.0.0.1')) { $ipv4[$domain] = $true }
            elseif ($parts[0] -in @('::','::1')) { $ipv6[$domain] = $true }
            else { $conflicts[$domain] = $true }
        }
    }
    return @($required | ForEach-Object { [pscustomobject]@{
        Domain=$_; IPv4Blocked=$ipv4.ContainsKey($_); IPv6Blocked=$ipv6.ContainsKey($_)
        ConflictingMapping=$conflicts.ContainsKey($_)
        Blocked=$ipv4.ContainsKey($_) -and $ipv6.ContainsKey($_) -and -not $conflicts.ContainsKey($_)
    } })
}
function Write-Diagnostic($Diagnostics, [string]$Event, $Data) {
    if ($null -eq $Diagnostics) { return }
    try { $Diagnostics.Record($Event, ($Data | ConvertTo-Json -Depth 8 -Compress)) } catch { }
}
function Get-HostsEvidence([string]$Path = "$env:SystemRoot\System32\drivers\etc\hosts") {
    try {
        # Read one stable byte buffer. A concurrent writer produces unknown evidence,
        # never a mixture of mappings from one revision and a hash from another.
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ($stream.Length -gt 4194304) { throw 'Hosts evidence size limit exceeded.' }
            $memory = [IO.MemoryStream]::new()
            try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $memory.Dispose() }
            $writeUtc = (Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToString('o')
        } finally { $stream.Dispose() }
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $algorithm.Dispose() }
        $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes), [Text.Encoding]::UTF8, $true)
        try { $mappings = @(Convert-HostsLines ($reader.ReadToEnd() -split '\r?\n')) } finally { $reader.Dispose() }
        return [pscustomobject]@{ReadState='ok';Length=$bytes.Length;WriteUtc=$writeUtc;Sha256=$hash;Mappings=$mappings;Complete=($mappings.Count -eq 3 -and @($mappings | Where-Object {-not $_.Blocked}).Count -eq 0);WriterAttribution='unknown'}
    } catch {
        return [pscustomobject]@{ReadState='unavailable';Length=$null;WriteUtc=$null;Sha256=$null;Mappings=@();Complete=$false;WriterAttribution='unknown'}
    }
}
function Get-HostsEvents($Previous, $Current) {
    if ($null -eq $Previous) {
        return @([pscustomobject]@{Event='hosts_baseline';Data=$Current})
    }
    $before = $Previous | ConvertTo-Json -Depth 6 -Compress
    $after = $Current | ConvertTo-Json -Depth 6 -Compress
    if ($before -ceq $after) { return @() }
    $events = @([pscustomobject]@{Event='hosts_changed';Data=[ordered]@{Before=$Previous;After=$Current;WriterAttribution='unknown'}})
    if ($Previous.ReadState -eq 'ok' -and $Current.ReadState -ne 'ok') {
        $events += [pscustomobject]@{Event='dns_protection_unknown';Data=@{ReadState=$Current.ReadState;WriterAttribution='unknown'}}
    } elseif ($Previous.Complete -and -not $Current.Complete) {
        $events += [pscustomobject]@{Event='dns_protection_lost';Data=[ordered]@{ReadState=$Current.ReadState;Mappings=$Current.Mappings;RequiresAdministrator=$true;WriterAttribution='unknown'}}
    } elseif ($Previous.ReadState -ne 'ok' -and $Current.ReadState -eq 'ok') {
        $events += [pscustomobject]@{Event='dns_protection_verified';Data=@{Complete=$Current.Complete;Mappings=$Current.Mappings;WriterAttribution='unknown'}}
    } elseif (-not $Previous.Complete -and $Current.Complete) {
        $events += [pscustomobject]@{Event='dns_protection_restored';Data=[ordered]@{Mappings=$Current.Mappings;WriterAttribution='unknown'}}
    }
    return $events
}
function Start-Diagnostics {
    if (-not ('KakaoAdDiagnostics.Session' -as [type])) {
        Add-Type -Path (Join-Path $script:Root 'Diagnostics.dll')
    }
    $observer = [KakaoAdDiagnostics.Session]::new($script:Root)
    try { $observer.Start(); return $observer } catch { Stop-Diagnostics $observer; throw }
}
function Stop-Diagnostics($Diagnostics) {
    if ($null -ne $Diagnostics) { try { $Diagnostics.Dispose() } catch { Write-Log 'diagnostics-dispose-failed' } }
}
function Complete-DiagnosticRepair($Diagnostics, [string]$Id, [bool]$Restarted) {
    if ($Diagnostics -and $Id) {
        try { $Diagnostics.CompleteRepair($Id, $Restarted) } catch { Write-Log 'diagnostics-complete-failed' }
    }
}
function Start-Launcher {
    Start-Process -FilePath (Join-Path $script:Root 'KakaoAdMaintenance.exe') -WindowStyle Hidden
}
function Invoke-Watch([bool]$Once) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = [Threading.Mutex]::new($false, ('Local\KakaoAdMaintenance-' + $sid))
    $locked = $false
    $diagnostics = $null
    $diagnosticsRetryAfter = [datetime]::MinValue
    $lastHostsEvidence = $null
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { return }
        if (Test-Path -LiteralPath $script:DisablePath) { return }
        $state = Read-State
        $lastSignature = $null
        $lastError = $null
        $failures = 0
        $rapidCrashes = 0
        $lastBlockerPid = $null
        $lastBlockerStart = [datetime]::MinValue
        $retryAfter = [datetime]::MinValue
        Write-Log ('supervisor-started pid=' + $PID)
        do {
            $automaticRepairId = $null
            try {
                if (Test-Path -LiteralPath $script:DisablePath) { break }
                if ($null -eq $diagnostics -and [datetime]::UtcNow -ge $diagnosticsRetryAfter) {
                    try {
                        $diagnostics = Start-Diagnostics
                        $lastHostsEvidence = $null
                        Write-Diagnostic $diagnostics 'supervisor_started' @{SupervisorPid=$PID}
                    } catch {
                        $diagnosticsRetryAfter = [datetime]::UtcNow.AddMinutes(1)
                        Write-Log 'diagnostics-start-failed; retry in one minute'
                    }
                }
                $snapshot = @(Get-KakaoSnapshot)
                $signature = Get-KakaoSignature $snapshot
                $changed = $null -ne $lastSignature -and $signature -cne $lastSignature
                if ($changed) { Write-Diagnostic $diagnostics 'kakao_process_or_version_changed' @{Processes=$snapshot} }
                $repair = Test-Path -LiteralPath $script:RequestPath
                $runningBefore = @(Get-OwnedBlockers)
                if ($diagnostics -and -not $repair -and -not $changed -and $runningBefore.Count -gt 0 -and [datetime]::UtcNow -ge $retryAfter) {
                    try { $automaticRepairId = $diagnostics.TryRequestRepair() } catch { Write-Log 'diagnostics-repair-query-failed' }
                }
                if ($repair) {
                    Remove-Item -LiteralPath $script:RequestPath -Force
                    $state.RejectedVersion = $null
                    $rapidCrashes = 0
                    $retryAfter = [datetime]::MinValue
                }
                $schedule = Get-ReleaseSchedule $state
                if ($schedule.ResetClock) {
                    $state.LastCheckUtc = $null
                    $state.NextCheckUtc = $null
                    Write-Log 'release-schedule-reset; invalid or future timestamps'
                    Write-Diagnostic $diagnostics 'release_schedule_reset' @{Reason='invalid_or_future_timestamps'}
                }
                if ($repair -or $schedule.Due -or ($changed -and $schedule.ElapsedHours -ge 1)) {
                    $state.LastCheckUtc = [datetime]::UtcNow.ToString('o')
                    Write-JsonAtomic $script:StatePath $state
                    try {
                        $null = Install-Latest $state
                        $lastError = $null
                        $state.NextCheckUtc = [datetime]::UtcNow.AddHours(24).ToString('o')
                        Write-Log 'release-check-completed'
                        Write-Diagnostic $diagnostics 'release_check_completed' @{BlockerVersion=$(if ($state.Current) {$state.Current.Version} else {$null})}
                    } catch {
                        $lastError = $_.Exception.Message
                        $state.NextCheckUtc = [datetime]::UtcNow.AddMinutes(15).ToString('o')
                        Write-Log ('release-check-failed ' + $lastError)
                        Write-Diagnostic $diagnostics 'release_check_failed' @{ExceptionType=$_.Exception.GetType().Name}
                    }
                    Write-JsonAtomic $script:StatePath $state
                }
                if ($changed -or $repair -or $automaticRepairId) {
                    Stop-OwnedBlockers
                    $lastBlockerPid = $null
                    if ($repair -or $changed) {
                        $retryAfter = [datetime]::MinValue
                        $rapidCrashes = 0
                    }
                    $reason = if ($repair) {'manual-request'} elseif ($automaticRepairId) {'persistent-popup-observed'} else {'kakao-process-or-version-change'}
                    Write-Log ('reapply reason=' + $reason)
                    Write-Diagnostic $diagnostics 'blocker_reapply_started' @{Reason=$reason;RequestId=$automaticRepairId}
                }
                if (Test-Path -LiteralPath $script:DisablePath) {
                    if ($automaticRepairId) {
                        Write-Diagnostic $diagnostics 'repair_cancelled' @{RequestId=$automaticRepairId;Reason='protection_paused'}
                        Complete-DiagnosticRepair $diagnostics $automaticRepairId $false
                        $automaticRepairId = $null
                    }
                    break
                }
                $running = @(Get-OwnedBlockers)
                if ($running.Count -eq 0 -and $null -ne $lastBlockerPid) {
                    if (([datetime]::UtcNow - $lastBlockerStart).TotalSeconds -lt 60) { $rapidCrashes++ }
                    else { $rapidCrashes = 1 }
                    $retryAfter = [datetime]::UtcNow.AddSeconds((Get-CrashDelay $rapidCrashes))
                    Write-Log ('blocker-exited; retry-delay-seconds=' + (Get-CrashDelay $rapidCrashes))
                    Write-Diagnostic $diagnostics 'blocker_exited' @{RetryDelaySeconds=(Get-CrashDelay $rapidCrashes)}
                    $lastBlockerPid = $null
                    if ($rapidCrashes -ge 3 -and $state.Previous -and (Test-Blocker $state.Previous)) {
                        $state.RejectedVersion = $state.Current.Version
                        $state.Current = $state.Previous
                        $state.Previous = $null
                        Write-JsonAtomic $script:StatePath $state
                        Write-Log 'rapid-crashes; rolled-back-to-previous-release'
                        Write-Diagnostic $diagnostics 'blocker_rolled_back' @{From=$state.RejectedVersion;To=$state.Current.Version;Reason='rapid_crashes'}
                    }
                }
                if ($state.Current -and $running.Count -eq 0 -and [datetime]::UtcNow -ge $retryAfter) {
                    try { Start-VerifiedBlocker $state.Current }
                    catch {
                        $lastError = $_.Exception.Message
                        if ($state.Previous -and (Test-Blocker $state.Previous)) {
                            Stop-OwnedBlockers
                            Start-VerifiedBlocker $state.Previous
                            $state.RejectedVersion = $state.Current.Version
                            $state.Current = $state.Previous
                            $state.Previous = $null
                            Write-JsonAtomic $script:StatePath $state
                            Write-Log 'rolled-back-to-previous-release'
                            Write-Diagnostic $diagnostics 'blocker_rolled_back' @{From=$state.RejectedVersion;To=$state.Current.Version;Reason='startup_failure'}
                        } else { throw }
                    }
                }
                $running = @(Get-OwnedBlockers)
                if ($automaticRepairId -and $diagnostics) {
                    Complete-DiagnosticRepair $diagnostics $automaticRepairId ($running.Count -gt 0)
                    $automaticRepairId = $null
                }
                if ($running.Count -gt 0 -and $lastBlockerPid -ne $running[0].Id) {
                    $lastBlockerPid = $running[0].Id
                    $lastBlockerStart = $running[0].StartTime.ToUniversalTime()
                }
                $lastSignature = $signature
                $failures = 0
                $hostsEvidence = Get-HostsEvidence
                foreach ($event in @(Get-HostsEvents $lastHostsEvidence $hostsEvidence)) { Write-Diagnostic $diagnostics $event.Event $event.Data }
                if ($diagnostics) { $lastHostsEvidence = $hostsEvidence }
                $diagnosticHealth = [pscustomobject]@{running=$false;reason='unavailable'}
                if ($diagnostics) {
                    try { $diagnosticHealth = $diagnostics.GetHealthJson() | ConvertFrom-Json } catch { }
                    if (-not $diagnosticHealth.running) {
                        $stoppedDiagnostics = $diagnostics; $diagnostics = $null
                        Stop-Diagnostics $stoppedDiagnostics
                        $diagnosticsRetryAfter = [datetime]::UtcNow.AddMinutes(1)
                        Write-Log 'diagnostics-stopped; retry in one minute'
                    }
                }
                Write-JsonAtomic $script:StatusPath ([ordered]@{UpdatedUtc=[datetime]::UtcNow.ToString('o');SupervisorPid=$PID;Enabled=$true;BlockerVersion=$(if ($state.Current) {$state.Current.Version} else {$null});BlockerPids=@(Get-OwnedBlockers | ForEach-Object {$_.Id});Kakao=$snapshot;Hosts=$hostsEvidence.Mappings;DnsProtectionComplete=$hostsEvidence.Complete;Diagnostics=$diagnosticHealth;LastReleaseCheckUtc=$state.LastCheckUtc;LastError=$lastError})
            } catch {
                if ($automaticRepairId -and $diagnostics) {
                    Complete-DiagnosticRepair $diagnostics $automaticRepairId $false
                    $automaticRepairId = $null
                }
                $lastError = $_.Exception.Message
                $failures++
                Write-Log ('watch-error ' + $lastError)
                Write-Diagnostic $diagnostics 'supervisor_error' @{ExceptionType=$_.Exception.GetType().Name;RetryDelaySeconds=(Get-CrashDelay $failures)}
                if (-not $Once) { Start-Sleep -Seconds (Get-CrashDelay $failures) }
            }
            if (-not $Once) { Start-Sleep -Seconds 5 }
        } while (-not $Once)
        if (Test-Path -LiteralPath $script:DisablePath) {
            Stop-OwnedBlockers
            Write-JsonAtomic $script:StatusPath ([ordered]@{UpdatedUtc=[datetime]::UtcNow.ToString('o');Enabled=$false;BlockerPids=@()})
            Write-Log 'supervisor-disabled'
        }
    } finally {
        if ($diagnostics) {
            Write-Diagnostic $diagnostics 'supervisor_stopped' @{Disabled=(Test-Path -LiteralPath $script:DisablePath)}
            Stop-Diagnostics $diagnostics
        }
        try { if ($locked) { $mutex.ReleaseMutex() } } finally { $mutex.Dispose() }
    }
}
if ($Mode -eq 'Library') { return }
switch ($Mode) {
    'History' {
        $historyPath = Join-Path $script:Root 'events.jsonl'
        if (Test-Path -LiteralPath $historyPath) { Get-Content -LiteralPath $historyPath -Tail 100 -Encoding UTF8 }
        else { 'No diagnostic events recorded yet.' }
    }
    'Status' { if (Test-Path -LiteralPath $script:StatusPath) { Get-Content -LiteralPath $script:StatusPath -Raw } else { 'Not started yet.' } }
    'Stop' { [IO.File]::WriteAllText($script:DisablePath, [datetime]::UtcNow.ToString('o')); Start-Sleep -Seconds 6; Stop-OwnedBlockers }
    'Resume' { if (Test-Path -LiteralPath $script:DisablePath) { Remove-Item -LiteralPath $script:DisablePath }; Start-Launcher }
    'Repair' { if (Test-Path -LiteralPath $script:DisablePath) { Remove-Item -LiteralPath $script:DisablePath }; [IO.File]::WriteAllText($script:RequestPath, [datetime]::UtcNow.ToString('o')); Start-Launcher }
    'Once' { Invoke-Watch $true }
    'Watch' { Invoke-Watch $false }
}
