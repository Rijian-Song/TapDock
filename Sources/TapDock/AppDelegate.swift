// TapDock
// Copyright (c) 2026 Rijian Song
// Copyright (c) 2026 L2M Group Ltd.
// Released under the MIT License. See LICENSE.

import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<PopoverView>!
    private var refreshTimer: Timer?
    private var popoverClosedAt: Date?
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        model.onChange = { [weak self] in
            self?.applyStatusAppearance()
        }
        model.onPopoverHeight = { [weak self] height in
            self?.applyPopoverHeight(height)
        }

        configureStatusItem()
        configurePopover()
        applyStatusAppearance()
        DockController.shared.start()
        model.requestAccessibilityPromptIfNeeded()
        model.refreshAccessibility()
        startRefreshTimer()
    }

    func applicationDidBecomeActive(_: Notification) {
        model.refreshAccessibility()
        model.refreshLoginItem()
    }

    func applicationWillTerminate(_: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        DockController.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    func popoverDidShow(_: Notification) {
        statusItem.button?.isHighlighted = true
        model.refreshAccessibility()
        model.refreshLoginItem()
        model.refreshMinimizeSetting()
    }

    func popoverDidClose(_: Notification) {
        statusItem.button?.isHighlighted = false
        popoverClosedAt = Date()
    }

    private func installMainMenu() {
        let appMenu = NSMenu()
        let quit = appMenu.addItem(
            withTitle: "Quit \(AppInfo.displayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        let root = NSMenu()
        let item = NSMenuItem()
        item.submenu = appMenu
        root.addItem(item)
        NSApp.mainMenu = root
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: PopoverMetrics.width, height: 340)
        self.popover = popover
        self.hostingController = hosting
    }

    private func applyStatusAppearance() {
        guard let button = statusItem?.button else { return }
        if button.image == nil {
            button.image = MenuBarIcon.image
        }
        button.alphaValue = model.isEnabled ? 1 : 0.45
        if !model.accessibilityTrusted {
            button.toolTip = "\(AppInfo.displayName) — grant Accessibility to use Dock clicks"
        } else if model.isEnabled {
            button.toolTip = AppInfo.displayName
        } else {
            button.toolTip = "\(AppInfo.displayName) — paused"
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // A transient popover closes on the same click that hits the status item.
        // Ignore that click so the panel does not immediately reopen.
        if let popoverClosedAt, Date().timeIntervalSince(popoverClosedAt) < 0.25 {
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func applyPopoverHeight(_ height: CGFloat) {
        guard let popover else { return }
        let size = NSSize(width: PopoverMetrics.width, height: height)
        guard popover.contentSize != size else { return }
        popover.contentSize = size
        hostingController?.preferredContentSize = size
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.refreshAccessibility()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
