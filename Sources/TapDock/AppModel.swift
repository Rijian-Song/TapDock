// TapDock
// Copyright (c) 2026 Rijian Song
// Copyright (c) 2026 L2M Group Ltd.
// Released under the MIT License. See LICENSE.

import ApplicationServices
import Cocoa
import ServiceManagement

enum ActionMode: String, CaseIterable, Identifiable {
    case hide
    case minimize

    var id: String { rawValue }
}

enum AppInfo {
    static var displayName: String {
        let bundle = Bundle.main
        let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        return display ?? name ?? "TapDock"
    }

    static var shortVersion: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (value?.isEmpty == false) ? value! : "0.1.0"
    }

    static var versionBadge: String { "v\(shortVersion)" }

    static let githubURL = URL(string: "https://github.com/Rijian-Song/TapDock")!

    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    static let loginItemsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )!
}

/// Menu-bar template image with explicit @1x, @2x, and @3x representations.
@MainActor
enum MenuBarIcon {
    static let pointSize = NSSize(width: 18, height: 18)
    static let image: NSImage = makeImage()

    private static func makeImage() -> NSImage {
        let image = NSImage(size: pointSize)
        for name in ["MenuBarIcon", "MenuBarIcon@2x", "MenuBarIcon@3x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            // Point size stays 18×18 so a 36px bitmap is @2x and a 54px bitmap is @3x.
            rep.size = pointSize
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        guard image.representations.isEmpty else { return image }
        let symbol = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: AppInfo.displayName)
        symbol?.isTemplate = true
        return symbol ?? image
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// Called on the main actor after a user-visible preference changes.
    var onChange: (@MainActor () -> Void)?
    /// Popover height reported by SwiftUI, in points.
    var onPopoverHeight: (@MainActor (CGFloat) -> Void)?

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            onChange?()
        }
    }

    @Published var actionMode: ActionMode {
        didSet {
            guard actionMode != oldValue else { return }
            UserDefaults.standard.set(actionMode.rawValue, forKey: Keys.actionMode)
            onChange?()
        }
    }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var minimizeIntoAppIcon = true
    @Published var statusMessage: String?

    private var lastPopoverHeight: CGFloat = 0

    private enum Keys {
        static let enabled = "tapdock.enabled"
        static let actionMode = "tapdock.actionMode"
        static let didRequestAccessibility = "tapdock.didRequestAccessibility"
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.enabled) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Keys.enabled)
        }
        let raw = defaults.string(forKey: Keys.actionMode) ?? ActionMode.hide.rawValue
        actionMode = ActionMode(rawValue: raw) ?? .hide
        accessibilityTrusted = AXIsProcessTrusted()
        refreshLoginItem()
        refreshMinimizeSetting()
    }

    func updatePopoverHeight(_ height: CGFloat) {
        let rounded = ceil(height)
        guard rounded > 1, rounded < 800, abs(rounded - lastPopoverHeight) > 0.5 else { return }
        lastPopoverHeight = rounded
        onPopoverHeight?(rounded)
    }

    func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        guard trusted != accessibilityTrusted else { return }
        accessibilityTrusted = trusted
        if trusted {
            // A global mouse monitor installed before trust does not start delivering.
            DockController.shared.reinstallMouseMonitor()
        }
        onChange?()
    }

    func refreshLoginItem() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginNeedsApproval = false
        case .requiresApproval:
            launchAtLogin = false
            launchAtLoginNeedsApproval = true
        case .notRegistered, .notFound:
            launchAtLogin = false
            launchAtLoginNeedsApproval = false
        @unknown default:
            launchAtLogin = false
            launchAtLoginNeedsApproval = false
        }
    }

    func refreshMinimizeSetting() {
        minimizeIntoAppIcon = Self.readMinimizeIntoApplicationIcon()
    }

    /// Asks macOS to show its Accessibility prompt once, so TapDock appears in the list.
    func requestAccessibilityPromptIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.didRequestAccessibility) else { return }
        defaults.set(true, forKey: Keys.didRequestAccessibility)
        promptForAccessibility()
    }

    func openAccessibilitySettings() {
        promptForAccessibility()
        NSWorkspace.shared.open(AppInfo.accessibilitySettingsURL)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        statusMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
        refreshLoginItem()
        onChange?()
    }

    func openLoginItemsSettings() {
        NSWorkspace.shared.open(AppInfo.loginItemsSettingsURL)
    }

    /// Turns on Dock's "Minimize windows into application icon" and restarts the Dock.
    func enableMinimizeIntoApplicationIcon() {
        statusMessage = nil
        let wrote = run("/usr/bin/defaults", [
            "write", "com.apple.dock", "minimize-to-application", "-bool", "true"
        ])
        if wrote {
            _ = run("/usr/bin/killall", ["Dock"])
        } else {
            statusMessage = "Could not update the Dock setting."
        }
        refreshMinimizeSetting()
        onChange?()
    }

    private func promptForAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func readMinimizeIntoApplicationIcon() -> Bool {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let value = CFPreferencesCopyAppValue(
            "minimize-to-application" as CFString,
            "com.apple.dock" as CFString
        )
        return (value as? Bool) ?? false
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
