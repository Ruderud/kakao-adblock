$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Maintenance.ps1') -Mode Library
$testRoot = Join-Path $PSScriptRoot ('work\tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot -Force
$script:Root = $testRoot
$script:StatePath = Join-Path $testRoot 'state.json'
$script:LogPath = Join-Path $testRoot 'test.log'
$script:Count = 0
function Assert($Condition, [string]$Description) {
    if (-not $Condition) { throw ('FAIL: ' + $Description) }
    $script:Count++
    'PASS: ' + $Description
}
function Assert-Reject($Action, [string]$Description) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    Assert $rejected $Description
}
function New-Release {
    return [pscustomobject]@{tag_name='2.2.5';draft=$false;prerelease=$false;assets=@([pscustomobject]@{name='KakaoTalkAdBlock_amd64.exe';size=6491136;digest='sha256:d9531550ddf03846b66c82abc0aa34fd9c7c6ff36ea7efff3fa35d8c986f81e2';browser_download_url='https://github.com/blurfx/KakaoTalkAdBlock/releases/download/2.2.5/KakaoTalkAdBlock_amd64.exe'})}
}
$release = New-Release
$spec = Get-ReleaseSpec $release
Assert ($spec.Version -eq '2.2.5') 'Official stable asset is accepted'
$release = New-Release; $release.tag_name='..\outside'
Assert-Reject { Get-ReleaseSpec $release } 'Path traversal tag rejected'
$release = New-Release; $release.assets[0].browser_download_url='https://example.com/payload.exe'
Assert-Reject { Get-ReleaseSpec $release } 'Third-party asset URL rejected'
$release = New-Release; $release.assets[0].digest=$null
Assert-Reject { Get-ReleaseSpec $release } 'Missing digest rejected'
$release = New-Release; $release.prerelease=$true
Assert-Reject { Get-ReleaseSpec $release } 'Prerelease rejected'
$release = New-Release; $release.assets += $release.assets[0]
Assert-Reject { Get-ReleaseSpec $release } 'Ambiguous duplicate asset rejected'
Assert-Reject { Get-BlockerPath ([pscustomobject]@{Version='..\other'}) } 'Persisted state cannot escape installation'

$one = @([pscustomobject]@{Pid=100;StartedUtc=1;Version='26.9.2';WriteTicks=2;Length=1000})
$restart = @([pscustomobject]@{Pid=100;StartedUtc=3;Version='26.9.2';WriteTicks=2;Length=1000})
$update = @([pscustomobject]@{Pid=100;StartedUtc=1;Version='26.10.0';WriteTicks=4;Length=1001})
Assert ((Get-KakaoSignature $one) -cne (Get-KakaoSignature $restart)) 'PID reuse after restart changes signature'
Assert ((Get-KakaoSignature $one) -cne (Get-KakaoSignature $update)) 'In-place application update changes signature'
Assert ((Get-CrashDelay 1) -eq 5 -and (Get-CrashDelay 3) -eq 20 -and (Get-CrashDelay 20) -eq 300) 'Repeated crash retries back off with a five-minute cap'

$now = [datetime]'2026-11-07T03:00:00Z'
$scheduleState = [pscustomobject]@{LastCheckUtc=$now.AddMinutes(-10).ToString('o');NextCheckUtc=$now.AddHours(23).ToString('o')}
$schedule = Get-ReleaseSchedule $scheduleState $now
Assert (-not $schedule.Due -and -not $schedule.ResetClock) 'Normal daily schedule remains deferred'
$scheduleState.LastCheckUtc = $now.AddYears(2).ToString('o'); $scheduleState.NextCheckUtc = $now.AddYears(2).AddDays(1).ToString('o')
$schedule = Get-ReleaseSchedule $scheduleState $now
Assert ($schedule.Due -and $schedule.ResetClock -and $schedule.ElapsedHours -ge 1) 'Clock rollback forces an update check instead of waiting years'
$scheduleState.LastCheckUtc = 'invalid'; $scheduleState.NextCheckUtc = 'invalid'
Assert ((Get-ReleaseSchedule $scheduleState $now).Due) 'Malformed persisted schedule cannot disable update checks'
$scheduleState.LastCheckUtc = $now.AddMinutes(-5).ToString('o'); $scheduleState.NextCheckUtc = $now.AddMinutes(10).ToString('o')
Assert (-not (Get-ReleaseSchedule $scheduleState $now).Due) 'Network retry delay is preserved'
$scheduleState.NextCheckUtc = $now.AddDays(3).ToString('o')
Assert ((Get-ReleaseSchedule $scheduleState $now).ResetClock) 'An implausibly distant next check is reset'
$scheduleState.NextCheckUtc = $now.AddMinutes(-10).ToString('o')
Assert ((Get-ReleaseSchedule $scheduleState $now).ResetClock) 'Reversed persisted timestamps trigger recovery'

$hostsFixture = Join-Path $testRoot 'hosts-fixture'
[IO.File]::WriteAllText($hostsFixture, '')
Assert (@(Get-HostsStatus $hostsFixture | Where-Object {$_.Blocked}).Count -eq 0) 'An empty hosts file is reported as unprotected'
[IO.File]::WriteAllText($hostsFixture, "0.0.0.0 display.ad.daum.net`n")
$dns = @(Get-HostsStatus $hostsFixture)[0]
Assert ($dns.IPv4Blocked -and -not $dns.IPv6Blocked -and -not $dns.Blocked) 'IPv4 alone is not reported as complete DNS protection'
[IO.File]::WriteAllText($hostsFixture, "127.0.0.1 DISPLAY.AD.DAUM.NET # local block`n::1 display.ad.daum.net`n")
Assert (@(Get-HostsStatus $hostsFixture)[0].Blocked) 'IPv4 and IPv6 blocks are recognized case-insensitively'
[IO.File]::AppendAllText($hostsFixture, "192.0.2.1 display.ad.daum.net`n")
$dns = @(Get-HostsStatus $hostsFixture)[0]
Assert ($dns.ConflictingMapping -and -not $dns.Blocked) 'Conflicting unblocked mappings prevent a false healthy result'

$evidence = Get-HostsEvidence $hostsFixture
$baseline = @(Get-HostsEvents $null $evidence)
Assert ($baseline.Count -eq 1 -and $baseline[0].Event -eq 'hosts_baseline') 'Initial hosts evidence is a baseline, not an invented deletion'
Assert (@(Get-HostsEvents $evidence $evidence).Count -eq 0) 'Unchanged DNS evidence does not flood the event journal'
$lines = @()
foreach ($domain in @('display.ad.daum.net','adimg.daumcdn.net','adimg6.kakaocdn.net')) { $lines += "0.0.0.0 $domain"; $lines += ":: $domain" }
[IO.File]::WriteAllText($hostsFixture, ($lines -join "`n"))
$complete = Get-HostsEvidence $hostsFixture
$restoredEvents = @(Get-HostsEvents $evidence $complete)
Assert ($complete.Complete -and $restoredEvents.Event -contains 'dns_protection_restored') 'Restored blocking is recorded as a transition'
[IO.File]::WriteAllText($hostsFixture, '')
$empty = Get-HostsEvidence $hostsFixture
$lostEvents = @(Get-HostsEvents $complete $empty)
Assert ($lostEvents.Event -contains 'hosts_changed' -and $lostEvents.Event -contains 'dns_protection_lost') 'Erased hosts entries retain before/after evidence and loss event'
Assert ($empty.WriterAttribution -eq 'unknown' -and $lostEvents[0].Data.WriterAttribution -eq 'unknown') 'A file change never attributes the writer to Kakao without evidence'
$missing = Get-HostsEvidence (Join-Path $testRoot 'missing-hosts')
Assert ($missing.ReadState -eq 'unavailable' -and -not $missing.Complete) 'Missing hosts is distinguishable from a successful readable snapshot'
Assert (@(Get-HostsEvents $complete $missing).Event -contains 'dns_protection_unknown') 'A read failure is unknown protection, not proof that rules were removed'
Assert (@(Get-HostsEvents $missing $complete).Event -contains 'dns_protection_verified') 'Readable protection after an error is verification, not an invented restore'
$lockedFixture = [IO.File]::Open($hostsFixture, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { Assert ((Get-HostsEvidence $hostsFixture).ReadState -eq 'unavailable') 'A concurrent writer cannot produce a mixed-revision DNS snapshot' } finally { $lockedFixture.Dispose() }
Assert (($lostEvents | ConvertTo-Json -Depth 8) -notmatch [regex]::Escape($testRoot)) 'DNS event data omits the local file path'

Write-JsonAtomic $script:StatePath ([pscustomobject]@{Current='original'})
Write-JsonAtomic $script:StatePath ([pscustomobject]@{Current='replacement'})
Assert ((Get-Content $script:StatePath -Raw | ConvertFrom-Json).Current -eq 'replacement') 'Atomic state replacement remains readable'
[IO.File]::WriteAllText($script:StatePath, '{broken')
$recovered = Read-State
Assert ($recovered.Current -eq 'original' -and $recovered.PSObject.Properties.Name -contains 'NextCheckUtc') 'Corrupt state recovers from backup with schema defaults'

$script:StopCalls=0
function Stop-OwnedBlockers { $script:StopCalls++ }
function Invoke-RestMethod { New-Release }
function Invoke-WebRequest { param([switch]$UseBasicParsing,$Uri,$OutFile,$TimeoutSec); [IO.File]::WriteAllBytes($OutFile, [byte[]]@(77,90,1,2)) }
$state = [pscustomobject]@{Current=[pscustomobject]@{Version='2.2.4';Sha256=('a'*64)};Previous=$null;LastCheckUtc=$null;RejectedVersion=$null}
Assert-Reject { Install-Latest $state } 'Corrupt download rejected before promotion'
Assert ($script:StopCalls -eq 0 -and $state.Current.Version -eq '2.2.4') 'Corrupt download leaves existing blocker and active version untouched'
Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot 'versions\2.2.5\KakaoTalkAdBlock_amd64.exe'))) 'Unverified executable is never promoted'
Assert (@(Get-ChildItem -LiteralPath $testRoot -Recurse -Filter '*.download').Count -eq 0) 'Failed download staging file is cleaned'
$state.Current.Version='3.0.0'
Assert-Reject { Install-Latest $state } 'Automatic downgrade rejected'

# Process ownership checks include directory boundaries and the interactive session.
function Get-Process {
    [pscustomobject]@{Id=1;SessionId=$script:Session;Path=(Join-Path $testRoot 'versions\2.2.5\KakaoTalkAdBlock_amd64.exe')}
    [pscustomobject]@{Id=2;SessionId=$script:Session;Path=(Join-Path $testRoot 'versions-other\KakaoTalkAdBlock_amd64.exe')}
    [pscustomobject]@{Id=3;SessionId=($script:Session+1);Path=(Join-Path $testRoot 'versions\2.2.5\KakaoTalkAdBlock_amd64.exe')}
}
$owned = @(Get-OwnedBlockers)
Assert ($owned.Count -eq 1 -and $owned[0].Id -eq 1) 'Only this installation and session is eligible for process control'
'Tests passed: ' + $script:Count

$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$diagnosticTests = Join-Path $testRoot 'Diagnostics.Tests.exe'
& $compiler /nologo /target:exe /optimize+ /define:DIAGNOSTICS_TESTS /codepage:65001 /reference:System.Web.Extensions.dll ('/out:' + $diagnosticTests) (Join-Path $PSScriptRoot 'Diagnostics.cs') (Join-Path $PSScriptRoot 'Diagnostics.Tests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Diagnostics test compilation failed.' }
& $diagnosticTests (Join-Path $testRoot 'diagnostics')
if ($LASTEXITCODE -ne 0) { throw 'Diagnostics tests failed.' }
