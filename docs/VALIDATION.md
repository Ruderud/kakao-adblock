# Validation status

Keep this record factual. Build success, background-process health and actual ad removal are separate checks.

## Windows

- 28 functional tests passed, including release/path validation, corrupt-download rejection, state recovery, ownership, retry timing, clock rollback and IPv4/IPv6 hosts diagnostics.
- The launcher compiled with the .NET Framework compiler.
- Bottom-banner removal and list expansion were visually verified on KakaoTalk 26.9.2.5342.
- Owned-blocker crash recovery, duplicate launch protection, manual repair and scheduled supervisor recovery were exercised.
- A separate popup was not reproduced for visual verification. A future real KakaoTalk update was not performed; version/restart detection was tested with synthetic inputs.

### Popup report follow-up: 2026-11-07

- A user reported a transient bottom-right ad. The installed upstream blocker was running, matched the official 2.2.5 asset hash and was still the latest stable release.
- The Windows hosts file was empty and DNS protection was absent. The process that cleared it was not identified. Persisted release-check timestamps were also far in the future, preventing a timely automatic update check.
- With native administrator authorization, the three previously configured ad domains were restored for IPv4 and IPv6 after verifying the file was still empty. The original empty file was backed up and the DNS cache was flushed. `Resolve-DnsName` returned only `0.0.0.0` for A and `::` for AAAA records for all three domains. The .NET address lookup returned `NoData`; that result alone was not treated as proof of blocking.
- The updated supervisor was installed, reset its future schedule, completed a fresh release check and started a new verified blocker process. Its status reported `DnsProtectionComplete: true` and no error. KakaoTalk itself was not restarted.
- The popup was not reproduced during diagnosis. Restoring DNS and restarting the blocker do not establish that every future popup will be suppressed; the upstream UI rules remain unchanged.

## macOS

- All 11 portable managed-hosts tests passed on Windows and on the macOS CI runner.
- The Swift helper compiled on macOS 26 ARM64 and all 7 geometry/version guard self-tests passed (`--self-test`). Windows also passed all 18 functional tests in the same [Platform checks run](https://github.com/Ruderud/kakao-adblock/actions/runs/42152577264).
- CI does not validate an actual KakaoTalk window or install the helper on a user's machine. Intel and older macOS versions remain unverified.
- On a macOS 26.2 ARM64 device, commit `96a27c7` was installed, all 11 hosts unit tests and 7 Swift self-tests passed, and strict helper code-signature verification returned success.
- The user LaunchAgent was registered and the installed helper launched. Direct manual repair succeeded, and the installed helper's status was fresh afterward. Sign-out/sign-in startup, pause/resume and crash recovery were not tested on this device.
- After the user granted Accessibility and a direct helper repair restarted it, `helper.accessibilityGranted` was `true` with `stale: false`. The helper still reported `unsupported_version_no_cover` with the overlay hidden because of the installed KakaoTalk version.
- The hosts action succeeded for all five domains, adding both IPv4 and IPv6 blocks. A backup was created and the DNS cache was flushed. The public management script from `96a27c7` was staged in the helper's private support directory with explicit user consent. The administrator verifier ran with `/usr/bin/python3 -I` from `/`, checked the expected SHA-256 and executed the same verified bytes.
- Resolver checks succeeded for all five domains and returned only loopback or unspecified addresses. `/etc/hosts` remained root-owned with mode `0644`.
- The inspected app version was 26.8.0, outside the 26.9.x cover selector. It cannot validate removal of the newer banner UI.
- The selector is experimental: real ad coverage, window ordering, multiple displays, light/dark appearance and popup behavior are not claimed as verified.
- The visual effect of DNS blocking on this device was not checked; successful resolver checks do not establish that every ad disappeared.
- The Mac helper does not implement popup removal or ad-slot height reclamation. It does not automatically download new project source or repair root-owned hosts from its user process.

Do not include a machine's name, user account, home path, serial number, private logs or screenshots in this file.
