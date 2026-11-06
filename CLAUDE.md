# Claude project guide

Follow [AGENTS.md](AGENTS.md) and [the agent maintenance playbook](docs/AGENT_PLAYBOOK.md).

Windows uses PowerShell 5.1 and a small .NET Framework launcher to supervise the upstream KakaoTalkAdBlock executable. macOS uses a locally built Swift Accessibility/AppKit helper plus a Python management CLI. Do not patch KakaoTalk itself.

Keep tests, diagnostics and remote-machine evidence private by default. The manuals define safe evidence collection, platform-specific repair, version gating, public reporting and validation boundaries.
