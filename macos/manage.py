#!/usr/bin/env python3
"""Build/install a local macOS cover helper; diagnostics never print personal paths."""
import argparse
from contextlib import ExitStack
import datetime
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

LABEL = "dev.kakao-adblock.maintenance"
APP_NAME = "Kakao Adblock Maintenance.app"
SOURCE = Path(__file__).resolve().parent
PROJECT = SOURCE.parent
DOMAINS = ("display.ad.daum.net", "analytics.ad.daum.net", "serv.ds.kakao.com",
           "adimg.daumcdn.net", "adimg6.kakaocdn.net")
BEGIN = "# BEGIN kakao-adblock managed ads"
END = "# END kakao-adblock managed ads"


class MaintenanceError(Exception):
    pass


def paths():
    home = Path.home()
    support = home / "Library/Application Support/KakaoAdblockMaintenance"
    app = home / "Applications" / APP_NAME
    return {
        "app": app, "binary": app / "Contents/MacOS/KakaoAdblock",
        "support": support, "disabled": support / "disabled",
        "status": support / "status.json",
        "plist": home / "Library/LaunchAgents" / (LABEL + ".plist"),
    }


def run(args, allowed=(0,)):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if result.returncode not in allowed:
        raise MaintenanceError("command_failed:" + Path(str(args[0])).name + ":" + str(result.returncode))
    return result


def managed_hosts(text, enabled=True):
    """Replace only our complete marker block, preserving all unrelated text."""
    lines = text.splitlines(keepends=True)
    begins = [i for i, line in enumerate(lines) if line.rstrip("\r\n") == BEGIN]
    ends = [i for i, line in enumerate(lines) if line.rstrip("\r\n") == END]
    if len(begins) != len(ends) or len(begins) > 1 or (begins and begins[0] >= ends[0]):
        raise MaintenanceError("malformed_managed_hosts_block")
    if begins:
        before = "".join(lines[:begins[0]])
        after = "".join(lines[ends[0] + 1:])
    else:
        before, after = text, ""
    if not enabled:
        return before + after
    for line in (before + after).splitlines():
        fields = line.split("#", 1)[0].split()
        if len(fields) > 1 and fields[0] not in ("0.0.0.0", "127.0.0.1", "::", "::1"):
            if any(alias.lower() in DOMAINS for alias in fields[1:]):
                raise MaintenanceError("conflicting_unmanaged_ad_domain")
    block = BEGIN + "\n" + "".join(f"0.0.0.0 {domain}\n:: {domain}\n" for domain in DOMAINS) + END + "\n"
    if before and not before.endswith("\n"):
        before += "\n"
    return before + block + after


def hosts_status(text):
    found = {domain: {"ipv4": False, "ipv6": False} for domain in DOMAINS}
    for line in text.splitlines():
        parts = line.split("#", 1)[0].split()
        if len(parts) < 2:
            continue
        for alias in parts[1:]:
            if alias.lower() in found:
                if parts[0] in ("0.0.0.0", "127.0.0.1"):
                    found[alias.lower()]["ipv4"] = True
                if parts[0] in ("::", "::1"):
                    found[alias.lower()]["ipv6"] = True
    return found


def atomic_bytes(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".kakao-adblock-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def job_loaded():
    return run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], allowed=tuple(range(256))).returncode == 0


def stop_job():
    if job_loaded():
        run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"])


def load_job():
    p = paths()
    if not p["plist"].is_file() or not p["binary"].is_file():
        raise MaintenanceError("not_installed")
    if not job_loaded():
        run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", p["plist"]])


def install():
    p = paths()
    if p["app"].is_symlink():
        raise MaintenanceError("app_symlink_refused")
    if p["app"].exists():
        try:
            info = plistlib.loads((p["app"] / "Contents/Info.plist").read_bytes())
            if info.get("CFBundleIdentifier") != LABEL:
                raise MaintenanceError("existing_app_is_not_owned")
        except (OSError, plistlib.InvalidFileException):
            raise MaintenanceError("existing_app_is_not_owned")
    build = PROJECT / "work/macos"
    build.mkdir(parents=True, exist_ok=True)
    with ExitStack() as temporary:
        build_root = Path(temporary.enter_context(tempfile.TemporaryDirectory(prefix="build-", dir=build)))
        staged = build_root / APP_NAME
        binary = staged / "Contents/MacOS/KakaoAdblock"
        binary.parent.mkdir(parents=True)
        arch = platform.machine()
        if arch not in ("arm64", "x86_64"):
            raise MaintenanceError("unsupported_architecture")
        run(["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-O", "-target", f"{arch}-apple-macosx12.0",
             "-framework", "AppKit", "-framework", "ApplicationServices",
             SOURCE / "KakaoAdblock.swift", "-o", binary])
        run([binary, "--self-test"])
        info = {"CFBundleIdentifier": LABEL, "CFBundleName": "Kakao Adblock Maintenance",
                "CFBundleExecutable": "KakaoAdblock", "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "12.0", "LSUIElement": True,
                "NSHighResolutionCapable": True}
        (staged / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", LABEL, staged])
        run(["/usr/bin/codesign", "--verify", "--strict", staged])
        p["app"].parent.mkdir(parents=True, exist_ok=True)
        p["support"].mkdir(parents=True, exist_ok=True, mode=0o700)
        backup_dir = p["support"] / "backups"
        backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        pending_root = Path(temporary.enter_context(tempfile.TemporaryDirectory(prefix=".kakao-install-", dir=p["app"].parent)))
        pending = pending_root / APP_NAME
        shutil.copytree(staged, pending)
        run(["/usr/bin/codesign", "--verify", "--strict", pending])
        was_loaded = job_loaded()
        stop_job()
        backup = None
        try:
            if p["app"].exists():
                # Keep duplicate bundle identities out of Applications/LaunchServices discovery.
                backup = backup_dir / ("app-" + datetime.datetime.now().strftime("%Y%m%d%H%M%S%f") + ".bundle")
                p["app"].rename(backup)
            pending.rename(p["app"])
        except Exception:
            if backup is not None and backup.exists() and not p["app"].exists():
                backup.rename(p["app"])
            if was_loaded:
                load_job()
            raise
        p["disabled"].unlink(missing_ok=True)
        job = {"Label": LABEL, "ProgramArguments": [str(p["binary"])], "RunAtLoad": True,
               "KeepAlive": {"SuccessfulExit": False}, "ThrottleInterval": 10,
               "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive"}
        atomic_bytes(p["plist"], plistlib.dumps(job))
        load_job()
        return {"installed": True, "launchAgentLoaded": job_loaded(), "hostsChanged": False,
                "permissionNote": "Use the menu item to request Accessibility if a supported ad region needs covering."}


def change_hosts(enabled):
    if os.geteuid() != 0:
        raise MaintenanceError("administrator_required_for_hosts")
    target = Path("/etc/hosts").resolve()
    if str(target) not in ("/etc/hosts", "/private/etc/hosts"):
        raise MaintenanceError("unexpected_hosts_target")
    original = target.read_bytes()
    changed = managed_hosts(original.decode("utf-8"), enabled).encode("utf-8")
    if changed == original:
        return {"changed": False, "hosts": hosts_status(original.decode("utf-8"))}
    stat = target.stat()
    backup_dir = Path("/var/backups/kakao-adblock")
    if backup_dir.is_symlink():
        raise MaintenanceError("backup_symlink_refused")
    backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(backup_dir, 0o700)
    backup = backup_dir / ("hosts-" + datetime.datetime.now().strftime("%Y%m%d%H%M%S%f"))
    atomic_bytes(backup, original)
    atomic_bytes(target, changed, stat.st_mode & 0o777)
    os.chown(target, stat.st_uid, stat.st_gid)
    # A nonzero flush result is reported without exposing stderr or local paths.
    cache = run(["/usr/bin/dscacheutil", "-flushcache"], allowed=tuple(range(256)))
    mdns = run(["/usr/bin/killall", "-HUP", "mDNSResponder"], allowed=(0, 1))
    return {"changed": True, "backupCreated": True, "dnsCacheFlushed": cache.returncode == 0 and mdns.returncode == 0,
            "hosts": hosts_status(changed.decode("utf-8"))}


def status():
    p = paths()
    result = {"platform": "macOS", "installed": p["binary"].is_file(), "launchAgentLoaded": job_loaded(),
              "paused": p["disabled"].exists(), "hosts": hosts_status(Path("/etc/hosts").read_text())}
    if p["status"].exists():
        # Explicit field allowlist protects reports even if a future helper stores more local data.
        saved = json.loads(p["status"].read_text())
        keys = ("schemaVersion", "helperVersion", "osVersion", "kakaoInstalled", "kakaoVersion", "kakaoBuild",
                "kakaoRunning", "accessibilityGranted", "permissionContext", "selectorSupported", "state", "overlayVisible", "updatedAt", "rebindCount")
        result["helper"] = {key: saved[key] for key in keys if key in saved}
        try:
            stamp = datetime.datetime.fromisoformat(saved["updatedAt"].replace("Z", "+00:00"))
            age = (datetime.datetime.now(datetime.timezone.utc) - stamp).total_seconds()
            fresh = result["launchAgentLoaded"] and 0 <= age <= 15
        except (KeyError, TypeError, ValueError):
            fresh = False
        result["helper"]["stale"] = not fresh
        if not fresh:
            # Last-known geometry is not a claim about a stopped or stalled process.
            result["helper"]["overlayVisible"] = None
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "status", "doctor", "inspect-layout", "repair", "pause", "resume", "uninstall", "hosts-plan", "hosts-apply", "hosts-remove"))
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise MaintenanceError("macos_required")
    if args.action not in ("hosts-apply", "hosts-remove") and os.geteuid() == 0:
        raise MaintenanceError("run_user_actions_without_sudo")
    p = paths()
    if args.action == "install":
        result = install()
    elif args.action == "status":
        result = status()
    elif args.action in ("doctor", "inspect-layout"):
        if not p["binary"].exists():
            raise MaintenanceError("not_installed")
        result = json.loads(run([p["binary"], "--" + args.action]).stdout)
    elif args.action == "hosts-plan":
        result = {"domains": DOMAINS, "requiresAdministrator": True, "hosts": hosts_status(Path("/etc/hosts").read_text())}
    elif args.action in ("hosts-apply", "hosts-remove"):
        result = change_hosts(args.action == "hosts-apply")
    elif args.action == "pause":
        atomic_bytes(p["disabled"], b"")
        result = {"paused": True}
    elif args.action == "uninstall":
        atomic_bytes(p["disabled"], b"")
        stop_job()
        p["plist"].unlink(missing_ok=True)
        result = {"disabled": True, "filesRetained": True, "hostsChanged": False}
    else:
        p["disabled"].unlink(missing_ok=True)
        load_job()
        run(["/bin/launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{LABEL}"])
        result = {"reapplied": True, "launchAgentLoaded": job_loaded()}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except MaintenanceError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        sys.exit(1)
    except Exception as exc:
        # Never leak a home path, username, command line or raw OS error in public diagnostics.
        print(json.dumps({"ok": False, "error": type(exc).__name__}))
        sys.exit(1)
