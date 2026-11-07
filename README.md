# Kakao Adblock Maintenance

A per-user Windows supervisor for [blurfx/KakaoTalkAdBlock](https://github.com/blurfx/KakaoTalkAdBlock), with an experimental macOS helper and an AI-agent maintenance playbook. Windows keeps the upstream UI blocker running, reapplies it when KakaoTalk restarts or changes version, and checks for stable blocker updates.

This project does not modify KakaoTalk binaries or read conversations. On Windows, UI blocking rules belong to the upstream project; its executable is downloaded at installation time and is not included in this repository. The macOS helper uses a separate, version-gated Accessibility/AppKit cover. This project is not affiliated with Kakao or the upstream maintainer.

## Platform guides

| Platform / task | Guide | Current scope |
| --- | --- | --- |
| Windows | The instructions below | Upstream banner/popup rules and automatic blocker maintenance. |
| macOS | [macOS setup and limitations](docs/MACOS.md) | Optional DNS block, locally built cover, user LaunchAgent; 26.9.x selector, experimental visual compatibility. |
| AI-agent follow-up | [Maintenance playbook](docs/AGENT_PLAYBOOK.md) | Privacy-preserving diagnosis, repair, selector updates, validation and publishing. |

AI agents should also read [AGENTS.md](AGENTS.md). See [validation status](docs/VALIDATION.md) for what has actually been tested.

## Windows requirements

- Windows x64 with Windows PowerShell 5.1 and the .NET Framework C# compiler.
- KakaoTalk for Windows.
- Internet access to GitHub for installation and update checks.

## Windows install

Keep the checkout in a writable, persistent local folder, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer compiles a small launcher, creates a `runtime` directory, and starts protection. It registers a current-user startup entry and a scheduled task with a logon trigger and a five-minute repeat. It does not request administrator privileges. If task registration is unavailable, the installer reports that only sign-in startup is installed.

Use the project-local runtime path instead of a virtualized AppData directory: a packaged parent application can redirect AppData writes to a path that Task Scheduler cannot see. If you move the checkout, rerun the installer to update startup paths.

## Controls

| File | Action |
| --- | --- |
| `Repair.cmd` | Check for an update and reapply protection; retry a previously rejected release. |
| `Pause.cmd` | Disable automatic protection. |
| `Resume.cmd` | Enable protection again. |
| `Status.cmd` | Show the local health snapshot. |
| `History.cmd` | Show recent local ad/DNS lifecycle events and recovery results. |
| `Uninstall.ps1` | Remove startup registration and stop protection; retain local files and existing hosts entries. |

Use `Pause.cmd` instead of the upstream tray icon's Exit action: the supervisor intentionally restarts an exited blocker. Some window layout changes persist until KakaoTalk is restarted manually.

## Maintenance behavior

- Checks KakaoTalk process IDs, start times, executable versions, modification times, and sizes every five seconds.
- Restarts only blocker processes owned by this installation and Windows session. It never stops KakaoTalk itself.
- Recovers an exited blocker with increasing retry delays, capped at five minutes. Repeated early exits can roll back to the previous working blocker release when one is available.
- Checks the official upstream GitHub release daily, and on a KakaoTalk change if at least one hour has passed since the last check. Failed network checks retry after 15 minutes.
- Resets invalid or implausibly future update timestamps after a system-clock correction, so an old future date cannot postpone checks indefinitely.
- Records ad-window lifecycle and hosts/DNS changes in a bounded local journal. Persistent popups matching the existing upstream pattern can request a rate-limited restart of the owned blocker. See [recurrence diagnostics](docs/DIAGNOSTICS.md) for evidence, privacy and limitations.
- Accepts only stable numeric release tags and the expected x64 asset URL. It verifies the download size and SHA-256 digest before launching the executable.
- Preserves the previous release for rollback and keeps backup state files for recovery.

Automatic updates trust the upstream GitHub repository and publisher. A digest from that same release verifies download integrity; it is not an independent publisher signature. Future KakaoTalk UI changes may require an upstream blocker update. This supervisor does not invent new ad-detection rules.

## Windows DNS and hosts

The supervisor checks whether these domains are already blocked in the Windows hosts file:

```text
display.ad.daum.net
adimg.daumcdn.net
adimg6.kakaocdn.net
```

Status reports IPv4 and IPv6 entries separately and flags conflicting mappings. `DnsProtectionComplete` is true only when all three domains have both families blocked without conflicts. This is a hosts-file check; verify actual resolver behavior separately.

The Windows supervisor does not add, remove, or repair hosts entries. DNS blocking must be configured separately with administrator authorization. If another application or a system reset removes these entries, a running UI blocker does not mean DNS protection is still active. UI filtering uses the upstream blocker's banner, lock-screen, and popup rules; effectiveness depends on the KakaoTalk version and UI structure. The [macOS CLI](docs/MACOS.md) provides separate, explicitly privileged commands for its own hosts block.

## Local data and privacy

The source contains no installation-specific account names, paths, or credentials. Runtime files are local and excluded from version control:

- `runtime/`: downloaded executables, local state, health snapshots, and logs.
- `work/`: temporary test data.
- Logs and snapshots can include process IDs, timestamps, executable versions, and exception messages; an exception may contain a local file path.

The supervisor does not read or record chat contents. Its own outbound requests are to GitHub for release metadata and downloads; the downloaded blocker is a separate upstream application. Do not attach unreviewed runtime files or screenshots to public issues.

## Tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests.ps1
```

The tests exercise release validation, path boundaries, corrupt downloads, state recovery, process ownership, restart/update signatures, and retry delays without changing KakaoTalk or the system hosts file. They do not establish compatibility with every future KakaoTalk release or reproduce every ad type.

The **Platform checks** GitHub Actions workflow runs these tests on Windows and compiles/tests the Swift helper on macOS. It does not install the helper, request permissions, change hosts or verify a real advertisement. See [validation status](docs/VALIDATION.md) for device-specific limitations.
