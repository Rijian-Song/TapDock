// TapDock
// Copyright (c) 2026 Rijian Song
// Copyright (c) 2026 L2M Group Ltd.
// Released under the MIT License. See LICENSE.
//
// Clicking the Dock icon of the already-frontmost app hides or minimizes it.
// A second click is left to the Dock, which shows or restores the app.
// Trackpad "Tap to Click" combined with three-finger drag synthesizes extra
// clicks during an app switch; the gate below drops those before they fire.

import ApplicationServices
import Cocoa
import os

/// Pure timing rules for Dock clicks. Kept free of Accessibility calls so the
/// trackpad guards stay obvious and independent of AppKit state.
enum DockClickGate {
    /// After an app becomes active, ignore a Dock re-click this long.
    /// A three-finger drag often ends with a click on the icon that just activated.
    static let appSwitchCooldown: TimeInterval = 0.40

    /// After TapDock accepts a Dock click, ignore another one this long.
    static let dockActionDebounce: TimeInterval = 0.45

    /// Let the original mouse-down reach the Dock, then confirm the target.
    static let confirmationDelay: TimeInterval = 0.15

    enum Block: String {
        case repeatedClick
        case debounced
        case appSwitchCooldown
    }

    static func block(
        clickCount: Int,
        now: Date,
        lastDockActionAt: Date?,
        lastAppActivatedAt: Date
    ) -> Block? {
        if clickCount > 1 {
            return .repeatedClick
        }
        if let lastDockActionAt, now.timeIntervalSince(lastDockActionAt) < dockActionDebounce {
            return .debounced
        }
        if now.timeIntervalSince(lastAppActivatedAt) < appSwitchCooldown {
            return .appSwitchCooldown
        }
        return nil
    }

    /// The delayed callback acts only when focus has not moved on and the
    /// activation stamp captured at mouse-down is still current.
    static func confirmationStillValid(
        scheduledStamp: Date,
        currentStamp: Date,
        targetStillFrontmost: Bool
    ) -> Bool {
        scheduledStamp == currentStamp && targetStillFrontmost
    }
}

@MainActor
final class DockController: NSObject {
    static let shared = DockController()

    override init() {
        super.init()
    }

    /// Set from `NSWorkspace.didActivateApplicationNotification` when the frontmost PID changes.
    private(set) var lastAppActivatedAt = Date()
    private(set) var lastActivatedPID: pid_t = 0

    private var lastDockActionAt: Date?
    private var mouseMonitor: Any?
    private var isObservingActivation = false
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.rijian-song.TapDock",
        category: "dock"
    )

    private let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
        "com.apple.screencaptureui"
    ]

    func start() {
        if let front = NSWorkspace.shared.frontmostApplication {
            lastActivatedPID = front.processIdentifier
        }
        lastAppActivatedAt = Date()

        if !isObservingActivation {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(appDidActivate(_:)),
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil
            )
            isObservingActivation = true
        }
        reinstallMouseMonitor()
    }

    /// Installs the global click monitor. Safe to call again after Accessibility
    /// is granted; a monitor created earlier does not begin receiving events.
    func reinstallMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        // The handler runs on the main thread, but it is Sendable and not
        // MainActor-isolated. assumeIsolated is the bridge, and it does not escape.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { event in
            MainActor.assumeIsolated {
                DockController.shared.handleGlobalClick(
                    clickCount: event.clickCount,
                    mouseLocation: NSEvent.mouseLocation
                )
            }
        }
        if mouseMonitor == nil {
            logger.info("global click monitor was not installed")
        }
    }

    func stop() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        if isObservingActivation {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            isObservingActivation = false
        }
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        let pid = app.processIdentifier
        // Same-app re-activation (some apps emit it on a Dock click) must not
        // move the stamp, or the confirmation delay would cancel a real hide.
        guard pid != lastActivatedPID else { return }
        lastActivatedPID = pid
        lastAppActivatedAt = Date()
    }

    private func handleGlobalClick(clickCount: Int, mouseLocation: CGPoint) {
        guard AppModel.shared.isEnabled else { return }
        guard let item = dockItem(at: mouseLocation) else { return }
        guard let front = NSWorkspace.shared.frontmostApplication, canTuck(front) else { return }
        guard dockItem(item, matches: front) else { return }

        let now = Date()
        if let reason = DockClickGate.block(
            clickCount: clickCount,
            now: now,
            lastDockActionAt: lastDockActionAt,
            lastAppActivatedAt: lastAppActivatedAt
        ) {
            switch reason {
            case .repeatedClick:
                logger.info("dock click ignored: clickCount=\(clickCount, privacy: .public)")
            case .debounced:
                let age = Self.seconds(from: lastDockActionAt ?? now, to: now)
                logger.info("dock click ignored: recent dock action \(age, privacy: .public)s ago")
            case .appSwitchCooldown:
                let age = Self.seconds(from: lastAppActivatedAt, to: now)
                logger.info("dock click ignored: app just activated \(age, privacy: .public)s ago")
            }
            return
        }

        // Hidden apps and fully minimized windows should come back, not tuck
        // away again. The Dock click itself performs that restore. Marking the
        // action time keeps a trackpad's extra click from undoing it.
        if shouldLeaveRestoreToSystem(front) {
            lastDockActionAt = now
            logger.info("dock click left to the system so the app can show or restore")
            return
        }

        let pid = front.processIdentifier
        let stamp = lastAppActivatedAt
        lastDockActionAt = now
        let delay = DockClickGate.confirmationDelay
        let pidNumber = Int(pid)
        logger.info("dock re-click on active app pid=\(pidNumber, privacy: .public)")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                DockController.shared.confirmAndPerform(pid: pid, activationStamp: stamp)
            }
        }
    }

    private func confirmAndPerform(pid: pid_t, activationStamp: Date) {
        guard AppModel.shared.isEnabled else { return }
        // Re-verify both conditions from the 0.15s delayed callback:
        // the activation stamp is unchanged, and the target is still frontmost.
        if lastAppActivatedAt != activationStamp {
            logger.info("dock re-click aborted: activation occurred after mouseDown (switch/restore)")
            return
        }
        let stillFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        guard DockClickGate.confirmationStillValid(
            scheduledStamp: activationStamp,
            currentStamp: lastAppActivatedAt,
            targetStillFrontmost: stillFrontmost
        ) else {
            logger.info("dock re-click aborted: target is no longer the frontmost app")
            return
        }
        guard let app = NSRunningApplication(processIdentifier: pid), canTuck(app) else { return }
        if shouldLeaveRestoreToSystem(app) {
            logger.info("dock re-click aborted: the app is already tucked away")
            return
        }
        performAction(on: app)
    }

    private func shouldLeaveRestoreToSystem(_ app: NSRunningApplication) -> Bool {
        if app.isHidden { return true }
        if AppModel.shared.actionMode == .minimize && allWindowsMinimized(app) {
            return true
        }
        return false
    }

    private func performAction(on app: NSRunningApplication) {
        switch AppModel.shared.actionMode {
        case .hide:
            if hide(app) {
                logger.info("hide returned yes")
            } else {
                logger.info("hide returned no")
            }
        case .minimize:
            if minimize(app) {
                logger.info("minimize returned yes")
            } else {
                logger.info("minimize returned no")
            }
        }
    }

    private func canTuck(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == NSRunningApplication.current.processIdentifier { return false }
        if app.activationPolicy != .regular { return false }
        if let bundleID = app.bundleIdentifier, excludedBundleIDs.contains(bundleID) { return false }
        return true
    }

    private func hide(_ app: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let error = AXUIElementSetAttributeValue(element, kAXHiddenAttribute as CFString, kCFBooleanTrue)
        if error == .success { return true }
        let code = Int(error.rawValue)
        logger.info("accessibility hide failed (\(code, privacy: .public)); using application hide")
        return app.hide()
    }

    private func minimize(_ app: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRaw) == .success,
              let windows = windowsRaw as? [AXUIElement],
              !windows.isEmpty else {
            logger.info("minimize found no windows; using application hide")
            return app.hide()
        }
        var any = false
        for window in windows {
            let error = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            if error == .success { any = true }
        }
        return any
    }

    /// True only when every listed window reports minimized. Unknown window
    /// state returns false so TapDock still tucks the app away.
    private func allWindowsMinimized(_ app: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRaw) == .success,
              let windows = windowsRaw as? [AXUIElement],
              !windows.isEmpty else {
            return false
        }
        for window in windows {
            var minimizedRaw: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRaw)
            if (minimizedRaw as? Bool) != true { return false }
        }
        return true
    }

    private func dockItem(at cocoaPoint: CGPoint) -> AXUIElement? {
        guard let axPoint = accessibilityPoint(fromCocoa: cocoaPoint) else { return nil }
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(axPoint.x), Float(axPoint.y), &element) == .success,
              let element else { return nil }
        var subroleRaw: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRaw)
        guard (subroleRaw as? String) == "AXApplicationDockItem" else { return nil }
        return element
    }

    private func dockItem(_ item: AXUIElement, matches app: NSRunningApplication) -> Bool {
        var urlRaw: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRaw)
        if let clicked = canonicalPath(from: urlRaw),
           let bundle = app.bundleURL,
           clicked == canonicalPath(bundle) {
            return true
        }
        var titleRaw: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRaw)
        if let title = titleRaw as? String,
           let name = app.localizedName,
           !title.isEmpty,
           title == name {
            return true
        }
        return false
    }

    /// Cocoa mouse location is bottom-left of the display whose origin is (0, 0).
    /// Accessibility positions are top-left of that same display, including
    /// negative coordinates for screens arranged to the left or below.
    private func accessibilityPoint(fromCocoa point: CGPoint) -> CGPoint? {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else { return nil }
        return CGPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    private func canonicalPath(from raw: CFTypeRef?) -> String? {
        guard let raw else { return nil }
        if let url = raw as? URL, url.isFileURL {
            return canonicalPath(url)
        }
        if let text = raw as? String {
            if text.hasPrefix("file:"), let url = URL(string: text), url.isFileURL {
                return canonicalPath(url)
            }
            if text.hasPrefix("/") {
                return canonicalPath(URL(fileURLWithPath: text))
            }
        }
        return nil
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func seconds(from start: Date, to end: Date) -> String {
        String(format: "%.3f", end.timeIntervalSince(start))
    }
}
