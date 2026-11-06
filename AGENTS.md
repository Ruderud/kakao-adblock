# Agent instructions

Read [the maintenance playbook](docs/AGENT_PLAYBOOK.md) before investigating an ad regression or changing platform support. Read [macOS support](docs/MACOS.md) for Mac tasks.

- Use the user's existing authorization and preserve unrelated work. Prefer supported CLI/filesystem APIs; use UI only for the step that needs visual evidence or user interaction.
- Keep changes scoped to this repository and its explicitly installed helper. Do not modify KakaoTalk binaries, signatures, conversations, accounts, permissions databases or unrelated settings.
- Windows UI filtering belongs to `blurfx/KakaoTalkAdBlock`. Validate the official asset URL, size and SHA-256 before execution. Preserve restart ownership checks and rollback behavior.
- macOS uses public Accessibility/AppKit APIs. Never read chat titles, text values or rows. Cover only the unique, version-gated main-window ad region; hide the overlay on unknown or ambiguous layouts.
- Accessibility and administrator approvals belong to the user. Hosts changes require the explicit macOS `hosts-apply`/`hosts-remove` action and manage only this project's marked block. Do not silently elevate.
- Keep personal paths, host identifiers, credentials, screenshots, raw logs, runtime files and proprietary binaries out of commits and public diagnostics. Use placeholders and the intended public Git identity.
- Run relevant portable tests, native compilation and actual UI checks. Report untested platform/version/permission cases accurately; a healthy process is not proof of successful visual blocking.
- Keep manuals and status descriptions aligned with the implementation. See the playbook for acceptance checks, publication hygiene and a sanitized handoff template.

Useful checks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests.ps1
```

```sh
python3 -m unittest discover -s macos -p test_manage.py -v
python3 macos/manage.py doctor
git diff --check
```
