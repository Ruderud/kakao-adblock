# macOS support

macOS support is experimental. The helper is built locally from the source in this repository. It uses an opaque AppKit panel to cover an unambiguously identified bottom ad region, without patching KakaoTalk or changing its signature. It does not shrink the ad slot and does not remove separate popup ads.

The current UI selector is limited to **KakaoTalk 26.9.x** and the known `Main Window` Accessibility layout. All other versions leave the cover hidden. An older version without an ad is not a valid visual test of this selector. A future layout change requires a checked selector update; automatic restart is not automatic invention of a new selector.

## Requirements

- macOS 12 or newer, Apple Silicon or Intel; each architecture still needs its own real-world validation.
- Python 3.9 or newer.
- Xcode or Command Line Tools with `xcrun swiftc` and `codesign`.
- An active GUI login session for the per-user LaunchAgent.
- User-granted Accessibility permission for UI covering. Screen recording is not required or requested.

## Install from the repository

```sh
git clone https://github.com/Ruderud/kakao-adblock.git
cd kakao-adblock
python3 -m unittest discover -s macos -p test_manage.py -v
python3 macos/manage.py install
python3 macos/manage.py status
```

Run these commands as the logged-in user, **without sudo**. The installer builds and checks a local app, signs that helper ad hoc, and installs it under `$HOME/Applications`. It creates a user LaunchAgent and a private support directory. It does not restart KakaoTalk, request a password, or change hosts.

To enable covering, choose **Request Accessibility Permission…** from the helper's `K•` menu and approve the helper yourself in macOS settings. Rebuilding an ad-hoc-signed helper may require granting permission again. No script edits the permissions database or bypasses the operating system's consent.

## DNS blocking

Preview the exact domain list and current rule status first:

```sh
python3 macos/manage.py hosts-plan
```

If you want the DNS layer, apply it separately with administrator authorization:

```sh
sudo /usr/bin/python3 -I macos/manage.py hosts-apply
```

Only the marked `kakao-adblock managed ads` block is managed. Unrelated hosts lines are preserved; malformed/duplicate markers or conflicting unmanaged mappings are rejected. A root-only backup is created before changing `/etc/hosts`. The script flushes the DNS cache and reports whether the flush succeeded. Domain blocking is system-wide, so these exact ad hosts are also blocked for other apps.

In remote automation, native administrator authentication can succeed while macOS still prevents the elevated interpreter from reading a protected checkout. If the source cannot be opened with `Operation not permitted`, stop and follow the [agent playbook's approved staging procedure](AGENT_PLAYBOOK.md#remote-approvals-and-user-permissions). Changing the execution location requires the user's consent, source-integrity checks and normal administrator authorization; it does not grant Accessibility permission.

Blocking ad requests may still leave a built-in promo or blank space. The helper's UI layer is separate. It does not install a local HTTPS server, certificate, proxy or root daemon. A later OS-level hosts reset is reported and requires the privileged command again; the user LaunchAgent cannot silently repair root-owned files.

To remove only this project's hosts block:

```sh
sudo /usr/bin/python3 -I macos/manage.py hosts-remove
```

## Maintenance commands

```sh
python3 macos/manage.py doctor
python3 macos/manage.py inspect-layout
python3 macos/manage.py repair
python3 macos/manage.py pause
python3 macos/manage.py resume
python3 macos/manage.py uninstall
```

`uninstall` stops and unregisters the user job. It retains the app, diagnostics and backups, and does not modify hosts. Run `hosts-remove` separately if you also want to undo the DNS block.

`doctor`, `status` and `inspect-layout` print JSON without account names, absolute installation paths, window titles or conversation text. The layout inspector reads only the recognized main window and its direct child roles/relative rectangles; it does not walk chat rows. No screenshot is captured. Review even these reports before posting them publicly.

The installed helper's permission is reported by `status` under `helper.accessibilityGranted`. A CLI invocation can have a different responsible process (Terminal or the remote runner); `doctor`/`inspect-layout` label that caller's trust separately as `callerAccessibilityGranted`. Do not infer the installed helper's permission from a remote shell's result. After rebuilding, if permission needs renewal, the user should remove/re-add or re-enable the helper in macOS settings themselves.

## Status meanings

| State | Meaning |
| --- | --- |
| `waiting_for_kakao` | KakaoTalk is not running in this session. |
| `unsupported_version_no_cover` | The version is outside the reviewed selector; no UI is covered. |
| `restart_required_after_update` | The bundle changed while KakaoTalk was running; cover stays hidden until KakaoTalk is restarted when convenient. |
| `needs_accessibility` | A supported version is present, but the helper lacks permission. |
| `no_unambiguous_ad_region` | The expected visible main window/ad geometry cannot be uniquely found. |
| `covering_known_ad_region` | A matching region is covered; visual verification is still needed. |
| `paused` | User-controlled pause is active. |

The helper rebinds when KakaoTalk's process or version changes. launchd restarts it after an abnormal exit. The menu's **Quit and Pause** intentionally disables it. `repair` restarts only this helper.

The version is bound to a process launch. A detected bundle change while that process is running leaves the cover hidden; the helper never restarts KakaoTalk automatically. File change times provide an additional guard when the helper itself restarts after an app update. `status` marks saved helper output as `stale` after 15 seconds or when the job is unloaded; stale `overlayVisible` is `null`, meaning unknown.

## Updating the source

From a clean checkout:

```sh
git pull --ff-only
python3 -m unittest discover -s macos -p test_manage.py -v
python3 macos/manage.py install
```

If local changes exist, review them first; do not reset them. macOS currently does not download and execute new project source automatically. An AI agent can follow [the maintenance playbook](AGENT_PLAYBOOK.md) to diagnose a changed ad and prepare a reviewed update. On unknown versions the UI cover remains off until that work is done.
