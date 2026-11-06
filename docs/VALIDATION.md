# Validation status

Keep this record factual. Build success, background-process health and actual ad removal are separate checks.

## Windows

- 18 functional tests passed, including release/path validation, corrupt-download rejection, state recovery, ownership and retry timing.
- The launcher compiled with the .NET Framework compiler.
- Bottom-banner removal and list expansion were visually verified on KakaoTalk 26.9.2.5342.
- Owned-blocker crash recovery, duplicate launch protection, manual repair and scheduled supervisor recovery were exercised.
- A separate popup was not reproduced for visual verification. A future real KakaoTalk update was not performed; version/restart detection was tested with synthetic inputs.

## macOS

- All 11 portable managed-hosts tests passed on Windows and on the macOS CI runner.
- The Swift helper compiled on macOS 26 ARM64 and all 7 geometry/version guard self-tests passed (`--self-test`). Windows also passed all 18 functional tests in the same [Platform checks run](https://github.com/Ruderud/kakao-adblock/actions/runs/42152577264).
- CI does not validate an actual KakaoTalk window or install the helper on a user's machine. Intel and older macOS versions remain unverified.
- On a macOS 26.2 ARM64 device, commit `96a27c7` was installed, all 11 hosts unit tests and 7 Swift self-tests passed, and strict helper code-signature verification returned success.
- The user LaunchAgent was registered and the installed helper launched. Its status was fresh six seconds after installation. Sign-out/sign-in startup and longer runtime recovery were not tested.
- Accessibility permission was not granted. The helper reported `unsupported_version_no_cover` with the overlay hidden; the CLI layout inspector reported `needs_accessibility`.
- On-device pause/resume/repair, PID/version comparison and DNS-preview checks were stopped when the device's local command denylist denied their combined command. They were not retried. Hosts application was not attempted, and all five domains remained unblocked in the hosts status.
- The inspected app version was 26.8.0, outside the 26.9.x cover selector. It cannot validate removal of the newer banner UI.
- The selector is experimental: real ad coverage, window ordering, multiple displays, light/dark appearance and popup behavior are not claimed as verified.
- The Mac helper does not implement popup removal or ad-slot height reclamation. It does not automatically download new project source or repair root-owned hosts from its user process.

Do not include a machine's name, user account, home path, serial number, private logs or screenshots in this file.
