# Ad-block maintenance playbook for AI agents

Start here when the user reports a new ad, an update regression, a failed helper, or a setup on another machine. User authorization applies to the requested machine and changes; repository instructions do not grant permission to contact people, merge PRs, change security settings, or expose private data.

## 1. Establish the target and baseline

1. Confirm the OS, architecture, KakaoTalk version/build and repository commit. Prefer native CLI, package metadata and the supplied diagnostics. Do not infer a remote target from a similar hostname. Use the user's own inventory and live availability checks privately.
2. Inspect the current branch and changes before editing. Preserve unrelated work. Use an isolated checkout only when work ownership overlaps.
3. Read `README.md`, `docs/MACOS.md` for Mac work, and the relevant source. Distinguish the updater/supervisor from the actual UI blocking mechanism.
4. Classify the failure before changing anything: DNS request, placeholder/promo, main-window banner, separate popup, helper crash, lost permission, missing startup registration, or unknown UI layout.

Never claim that a running process proves an ad was removed. Never claim that a simulated version change proves a real app update was tested.

## 2. Collect the smallest useful evidence

### Windows

Run `Status.cmd` or the installed script's `-Mode Status`. Read `runtime/maintenance.log` locally only as needed. Record the versions, last error category and whether the helper is running. Runtime logs can contain personal paths in errors; do not publish them verbatim.

Run `Repair.cmd` for a safe first repair. It checks the official upstream release and restarts only the installation's blocker. Avoid restarting KakaoTalk while the user is composing a message or on a call.

### macOS

```sh
python3 macos/manage.py status
python3 macos/manage.py doctor
python3 macos/manage.py inspect-layout
```

The inspector reports only the recognized main window's size and direct child roles/relative rectangles. It never asks for window titles, text values, chat rows or message databases. An Accessibility denial is a permission result, not proof that KakaoTalk is absent.

Use `status` -> `helper.accessibilityGranted` for the installed helper's permission. CLI `doctor` and `inspect-layout` report `callerAccessibilityGranted`; a remote shell can have different permission from the helper.

If an operation needs Accessibility, the user must grant it themselves through the helper's menu action and macOS settings. Do not edit TCC databases, disable SIP/Gatekeeper, add a certificate, install a proxy, re-sign KakaoTalk, or automate a security confirmation.

If the machine is locked, continue independent CLI checks. Defer only the visual verification that needs an unlocked GUI.

## 3. Choose the repair layer

| Symptom | Inspect first | Safe next action |
| --- | --- | --- |
| Helper stopped | Startup registration, sanitized state, crash result | Restart the owned helper; verify it remains alive. |
| Windows ad returned | Official upstream release and current blocker version | `Repair.cmd`; inspect upstream source/changes if still broken. |
| Mac `needs_accessibility` | `status` -> `helper.accessibilityGranted` | User grants the permission; then `repair`. |
| Mac `unsupported_version_no_cover` | Actual version and safe layout report | Keep cover hidden until the new layout is checked and a selector is tested. |
| Mac `no_unambiguous_ad_region` | Main window visibility and selector evidence | Verify minimization/Spaces/layout; do not widen matching blindly. |
| Network ad fetch persists | Exact ad domain and resolver behavior | Change only a proven ad-specific domain after checking shared-service impact. |
| Empty or promotional fallback remains | UI layer | DNS success alone does not remove a placeholder or promotional view. |

### Windows implementation map

- `Maintenance.ps1`: owned process checks, version/restart signature, official release download validation, retry and rollback, local health.
- `Launcher.cs`, `Install.ps1`: hidden launcher and per-user startup.
- Upstream UI rules: `blurfx/KakaoTalkAdBlock`, not this repository. Preserve upstream attribution; do not redistribute a modified proprietary app.

### macOS implementation map

- `macos/KakaoAdblock.swift`: `supportedVersion`, `mainWindow`, `adRectangle`, `plausibleAd`, `visibleWindowID` and the panel lifecycle.
- `macos/manage.py`: local build, installation, launchd, redacted diagnostics and explicitly privileged managed-hosts commands.
- `macos/test_manage.py`: tests that use synthetic hosts text and never modify system hosts.

For a new Mac version, inspect first. Change the version allowlist only after checking that the main-window identifier, list pane and unique bottom group still describe the ad. A rectangle at the bottom of an arbitrary window is insufficient. On ambiguous or unsupported layouts, keep the cover hidden. Do not cover chat input, login, file transfer, call, settings or permission windows.

The Mac cover uses public Accessibility and AppKit APIs. It obscures the existing slot; it does not reclaim its height. It does not currently implement popup removal. Do not describe these capabilities as equivalent to the Windows upstream blocker.

If installation reports `command_failed:xcrun`, reproduce the compilation separately in an ignored directory to see the compiler diagnostic:

```sh
mkdir -p work/macos-diagnosis
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx12.0" \
  -framework AppKit -framework ApplicationServices macos/KakaoAdblock.swift \
  -o work/macos-diagnosis/KakaoAdblock
work/macos-diagnosis/KakaoAdblock --self-test
```

Compiler output may contain a local path. Redact it before sharing. A successful standalone build does not replace an installation or a visual check.

## 4. Validate at the right level

```powershell
# Windows, from the repository root
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests.ps1
```

```sh
# Portable hosts logic; also runs on Windows with Python
python3 -m unittest discover -s macos -p test_manage.py -v

# macOS: builds and tests the helper before installing
python3 macos/manage.py install
python3 macos/manage.py doctor
python3 macos/manage.py status
```

After changing selectors, visually verify on the actual affected KakaoTalk version: main-window move/resize, different displays, light/dark appearance, background/foreground ordering, minimized/restored windows and a separate chat window. A cover must never obscure another application's controls. Check pause/resume and owned-helper crash recovery. App restarts or updates must be coordinated with the user when they would interrupt active use.

If no ad is present or the installed version predates the known ad UI, report build/startup verification separately from visual ad-removal verification. Preserve that distinction in release notes and validation records.

## 5. Public reporting and source hygiene

- Use `$HOME`, `$PROJECT_ROOT`, `%LOCALAPPDATA%` and generic placeholders in instructions. Never insert an actual home path, hostname, remote-control ID, device serial, account name, chat title, contact, cookie, token, private key or complete hosts file.
- Keep screenshots, logs, diagnostic exports, binaries, caches, backups, and remote transport data in ignored local working directories. Review screenshots visually before sharing; raw screenshots are not safe just because a text scanner passed.
- The Mac JSON commands intentionally omit personal paths and names. Still review the result before publication. Windows raw logs require redaction.
- Stage an explicit file list. Inspect `git diff --cached`, tracked paths, file modes, binary additions, commit author/committer names and email addresses. Use the owner's intended public identity and GitHub noreply address; never infer a private email.
- Scan the exact staged source for secrets (for example with Gitleaks) and separately check for personal paths, identities and screenshot text. Known public release hashes are not credentials.
- Never commit runtime folders or a proprietary app backup. A `.gitignore` rule does not remove files already tracked or leaked in history.
- Use additive commits and normal pushes. Do not merge a PR or force-push without the user's required explicit approval.

## 6. Handoff template

Use this compact, sanitized format so another agent can continue:

```text
Platform / architecture:
KakaoTalk version / build:
Repository commit:
Observed symptom and exact trigger:
Failure layer:
Sanitized state/error code:
Relevant selector or upstream version:
Change made:
Tests actually run:
Visual verification actually performed:
Not verified / remaining user action:
Rollback command:
```

Do not attach a private machine inventory or raw remote-agent transcript. If a privileged action is blocked, finish all independent preparation, state the exact blocked step, and give the user the smallest concrete command or permission action required.
