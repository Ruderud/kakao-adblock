# Validation status

Keep this record factual. Build success, background-process health and actual ad removal are separate checks.

## Windows

- 18 functional tests passed, including release/path validation, corrupt-download rejection, state recovery, ownership and retry timing.
- The launcher compiled with the .NET Framework compiler.
- Bottom-banner removal and list expansion were visually verified on KakaoTalk 26.9.2.5342.
- Owned-blocker crash recovery, duplicate launch protection, manual repair and scheduled supervisor recovery were exercised.
- A separate popup was not reproduced for visual verification. A future real KakaoTalk update was not performed; version/restart detection was tested with synthetic inputs.

## macOS

- All 11 portable managed-hosts tests passed on Windows.
- The Swift helper includes geometry/version guard self-tests (`--self-test`).
- Native CI build results are available in the repository's **Platform checks** workflow. CI does not validate an actual KakaoTalk window or install the helper on a user's machine.
- Target-machine metadata was inspected. Native installation and runtime checks were blocked by remote-command approval timeout; no helper, LaunchAgent or hosts changes were applied there.
- The inspected app version was 26.8.0, outside the 26.9.x cover selector. It cannot validate removal of the newer banner UI.
- The selector is experimental: real ad coverage, window ordering, multiple displays, light/dark appearance and popup behavior are not claimed as verified.
- The Mac helper does not implement popup removal or ad-slot height reclamation. It does not automatically download new project source or repair root-owned hosts from its user process.

Do not include a machine's name, user account, home path, serial number, private logs or screenshots in this file.
