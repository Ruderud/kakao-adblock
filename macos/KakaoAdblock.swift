import AppKit
import ApplicationServices
import Darwin

// Public Accessibility and AppKit APIs only. Never read AXTitle, AXValue or chat rows.
let kakaoBundle = "com.kakao.KakaoTalkMac"
let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/KakaoAdblockMaintenance", isDirectory: true)
let statusURL = supportDirectory.appendingPathComponent("status.json")
let disabledURL = supportDirectory.appendingPathComponent("disabled")

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func rectangle(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute),
          let s = attribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
          AXValueGetValue(s as! AXValue, .cgSize, &size),
          origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
    return CGRect(origin: origin, size: size)
}

func plausibleAd(main: CGRect, candidate: CGRect) -> Bool {
    return main.width >= 250 && main.height >= 300 &&
        candidate.height >= 40 && candidate.height <= 160 && candidate.height < main.height * 0.35 &&
        abs(candidate.minX - main.minX) <= 2 && abs(candidate.width - main.width) <= 2 &&
        abs(candidate.maxY - main.maxY) <= 2
}

func supportedVersion(_ version: String) -> Bool {
    // Deliberately fail closed on a new UI release until its structure is checked.
    let parts = version.split(separator: ".")
    return parts.count >= 2 && parts[0] == "26" && parts[1] == "9"
}

func bundleUnchangedSinceLaunch(_ app: NSRunningApplication) -> Bool {
    guard let launched = app.launchDate, let bundle = app.bundleURL,
          let executable = app.executableURL else { return false }
    // ctime also catches replacement when an updater preserves modification times.
    for url in [bundle.appendingPathComponent("Contents/Info.plist"), executable] {
        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0 else { return false }
        let changed = Double(metadata.st_ctimespec.tv_sec) + Double(metadata.st_ctimespec.tv_nsec) / 1_000_000_000
        guard changed <= launched.timeIntervalSince1970 else { return false }
    }
    return true
}

func mainWindow(_ app: NSRunningApplication) -> AXUIElement? {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.3)
    let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let matches = windows.filter { attribute($0, kAXIdentifierAttribute) as? String == "Main Window" }
    return matches.count == 1 ? matches[0] : nil
}

func adRectangle(_ window: AXUIElement, main: CGRect) -> CGRect? {
    let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
    // A list pane must also exist; this prevents matching a chat input or login window.
    guard children.contains(where: { attribute($0, kAXRoleAttribute) as? String == kAXScrollAreaRole }) else { return nil }
    let matches = children.compactMap { child -> CGRect? in
        guard attribute(child, kAXRoleAttribute) as? String == kAXGroupRole,
              let rect = rectangle(child), plausibleAd(main: main, candidate: rect) else { return nil }
        return rect
    }
    return matches.count == 1 ? matches[0] : nil
}

func visibleWindowID(pid: pid_t, rect: CGRect) -> Int? {
    // Window titles are intentionally never accessed from these dictionaries.
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let matches = windows.compactMap { item -> Int? in
        guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = item[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? NSNumber, let y = bounds["Y"] as? NSNumber,
              let w = bounds["Width"] as? NSNumber, let h = bounds["Height"] as? NSNumber,
              abs(CGFloat(x.doubleValue) - rect.minX) < 3, abs(CGFloat(y.doubleValue) - rect.minY) < 3,
              abs(CGFloat(w.doubleValue) - rect.width) < 3, abs(CGFloat(h.doubleValue) - rect.height) < 3 else { return nil }
        return (item[kCGWindowNumber as String] as? NSNumber)?.intValue
    }
    return matches.count == 1 ? matches[0] : nil
}

func basicStatus(context: String = "calling_process") -> [String: Any] {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: kakaoBundle).first
    let installed = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: kakaoBundle)
    // Read the running app's plist afresh. Bundle caches can retain an old version after an update.
    var info: [String: Any] = [:]
    if let url = installed?.appendingPathComponent("Contents/Info.plist"),
       let data = try? Data(contentsOf: url),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
        info = plist
    }
    let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
    var result: [String: Any] = ["schemaVersion": 1, "platform": "macOS", "helperVersion": "1.0.0",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "kakaoInstalled": installed != nil, "kakaoVersion": version,
            "kakaoBuild": info["CFBundleVersion"] as? String ?? "unknown",
            "kakaoRunning": running != nil, "permissionContext": context, "selectorSupported": supportedVersion(version),
            "paused": FileManager.default.fileExists(atPath: disabledURL.path)]
    result[context == "installed_helper" ? "accessibilityGranted" : "callerAccessibilityGranted"] = AXIsProcessTrusted()
    return result
}

func jsonData(_ object: [String: Any]) -> Data {
    return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
}

func printJSON(_ object: [String: Any]) { print(String(decoding: jsonData(object), as: UTF8.self)) }

func writeStatus(_ object: [String: Any]) {
    do {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try jsonData(object).write(to: statusURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statusURL.path)
    } catch { /* Diagnostics must not terminate protection; never log raw paths. */ }
}

func inspectLayout() -> [String: Any] {
    var result = basicStatus()
    guard AXIsProcessTrusted() else { result["state"] = "needs_accessibility"; return result }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: kakaoBundle).first,
          let window = mainWindow(app), let bounds = rectangle(window) else {
        result["state"] = "no_unambiguous_main_window"; return result
    }
    let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
    let allowed = [kAXGroupRole, kAXScrollAreaRole, kAXButtonRole, kAXToolbarRole, kAXSplitGroupRole]
    result["mainSize"] = ["width": Int(bounds.width), "height": Int(bounds.height)]
    result["directChildren"] = children.compactMap { child -> [String: Any]? in
        guard let role = attribute(child, kAXRoleAttribute) as? String, allowed.contains(role),
              let rect = rectangle(child) else { return nil }
        return ["role": role, "x": Int(rect.minX - bounds.minX), "y": Int(rect.minY - bounds.minY),
                "width": Int(rect.width), "height": Int(rect.height)]
    }
    result["state"] = "layout_inspected_without_text"
    return result
}

final class CoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private lazy var panel = CoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
    private var lastStatus = ""
    private var lastWrite = Date.distantPast
    private var boundVersion = ""
    private var previousLaunch: Date?
    private var previousPID: pid_t = 0
    private var rebindCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel.level = .normal
        panel.hasShadow = false
        panel.isOpaque = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false // Consume clicks over the ad; never forward them.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "K•"
        let menu = NSMenu()
        menu.addItem(withTitle: "Kakao Adblock Maintenance", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        add(menu, "Request Accessibility Permission…", #selector(requestPermission))
        add(menu, "Reapply", #selector(reapply))
        add(menu, "Pause", #selector(pauseProtection))
        add(menu, "Resume", #selector(resumeProtection))
        menu.addItem(NSMenuItem.separator())
        add(menu, "Quit and Pause", #selector(quitProtection))
        item.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }
    @objc private func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options) // Only this explicit menu action can prompt.
    }
    @objc private func reapply() { panel.orderOut(nil); previousPID = 0; tick() }
    @objc private func pauseProtection() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? Data().write(to: disabledURL)
        tick()
    }
    @objc private func resumeProtection() { try? FileManager.default.removeItem(at: disabledURL); tick() }
    @objc private func quitProtection() { pauseProtection(); NSApp.terminate(nil) }

    private func finish(_ state: String, _ base: [String: Any], visible: Bool = false) {
        if !visible { panel.orderOut(nil) }
        var output = base
        output["state"] = state
        output["overlayVisible"] = visible
        output["rebindCount"] = rebindCount
        output["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        if state != lastStatus || Date().timeIntervalSince(lastWrite) >= 5 {
            writeStatus(output)
            lastWrite = Date()
            lastStatus = state
        }
        item.button?.toolTip = "Kakao Adblock: \(state)"
    }

    private func tick() {
        let status = basicStatus(context: "installed_helper")
        guard status["paused"] as? Bool == false else { finish("paused", status); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: kakaoBundle).first else {
            previousPID = 0; finish("waiting_for_kakao", status); return
        }
        let version = status["kakaoVersion"] as? String ?? "unknown"
        if previousPID != app.processIdentifier || previousLaunch != app.launchDate {
            panel.orderOut(nil); previousPID = app.processIdentifier; previousLaunch = app.launchDate
            boundVersion = version; rebindCount += 1
        }
        guard supportedVersion(version) else { finish("unsupported_version_no_cover", status); return }
        guard version == boundVersion, bundleUnchangedSinceLaunch(app) else {
            finish("restart_required_after_update", status); return
        }
        guard AXIsProcessTrusted() else { finish("needs_accessibility", status); return }
        guard !app.isHidden, let window = mainWindow(app),
              attribute(window, kAXMinimizedAttribute) as? Bool != true,
              let main = rectangle(window), let ad = adRectangle(window, main: main),
              let number = visibleWindowID(pid: app.processIdentifier, rect: main) else {
            finish("no_unambiguous_ad_region", status); return
        }
        let origin = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        let target = CGRect(x: ad.minX, y: origin - ad.maxY, width: ad.width, height: ad.height)
        panel.backgroundColor = NSColor.windowBackgroundColor
        if panel.frame != target { panel.setFrame(target, display: true) }
        panel.order(.above, relativeTo: number)
        finish("covering_known_ad_region", status, visible: true)
    }
}

AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
if CommandLine.arguments.contains("--self-test") {
    let main = CGRect(x: 20, y: 20, width: 400, height: 700)
    let valid = CGRect(x: 20, y: 619, width: 400, height: 101)
    let checks = [plausibleAd(main: main, candidate: valid),
                  !plausibleAd(main: main, candidate: CGRect(x: 20, y: 20, width: 400, height: 101)),
                  !plausibleAd(main: main, candidate: CGRect(x: 20, y: 300, width: 400, height: 420)),
                  !plausibleAd(main: main, candidate: CGRect(x: 30, y: 619, width: 390, height: 101)),
                  supportedVersion("26.9.0"), !supportedVersion("26.8.0"), !supportedVersion("26.10.0")]
    printJSON(["passed": checks.allSatisfy { $0 }, "checks": checks.count])
    exit(checks.allSatisfy { $0 } ? 0 : 1)
} else if CommandLine.arguments.contains("--doctor") {
    printJSON(basicStatus())
} else if CommandLine.arguments.contains("--inspect-layout") {
    printJSON(inspectLayout())
} else {
    let application = NSApplication.shared
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
