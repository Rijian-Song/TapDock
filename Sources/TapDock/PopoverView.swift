// TapDock
// Copyright (c) 2026 Rijian Song
// Copyright (c) 2026 L2M Group Ltd.
// Released under the MIT License. See LICENSE.

import SwiftUI

enum TapDockColor {
    /// Ice blue sampled from the center control of the app icon.
    static let ice = Color(red: 0.45, green: 0.73, blue: 0.94)
}

struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}

enum PopoverMetrics {
    static let width: CGFloat = 292
}

private struct PopoverHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            actionSection
            Divider()
            loginSection
            accessibilitySection
            Divider()
            footer
        }
        .frame(width: PopoverMetrics.width)
        .fixedSize(horizontal: true, vertical: true)
        .background(PopoverMaterial())
        .background(heightReader)
        .onPreferenceChange(PopoverHeightKey.self) { newHeight in
            // Hop out of the current view update before resizing the popover.
            Task { @MainActor in
                model.updatePopoverHeight(newHeight)
            }
        }
    }

    private var heightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PopoverHeightKey.self, value: proxy.size.height)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: applicationIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(AppInfo.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(AppInfo.versionBadge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isEnabled ? TapDockColor.ice : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(model.isEnabled ? "Active" : "Paused")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Toggle(isOn: $model.isEnabled) {
                Text(model.isEnabled ? "Active" : "Paused")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(model.isEnabled ? "Active" : "Paused")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Action")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Action", selection: $model.actionMode) {
                Text("Hide").tag(ActionMode.hide)
                Text("Minimize").tag(ActionMode.minimize)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(actionCaption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.actionMode == .minimize && !model.minimizeIntoAppIcon {
                Button("Turn on Minimize into application icon") {
                    model.enableMinimizeIntoApplicationIcon()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)

                Text("Restarts the Dock so minimized windows collect on the app icon.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: launchBinding) {
                Text("Launch at Login")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.launchAtLoginNeedsApproval {
                Button("Approve in System Settings") {
                    model.openLoginItemsSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            }

            if let statusMessage = model.statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, model.accessibilityTrusted ? 4 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var accessibilitySection: some View {
        if model.accessibilityTrusted {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                Text("Accessibility granted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Accessibility is off", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text("TapDock needs Accessibility to see Dock clicks. It does not record your screen or read your data.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    model.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(AppInfo.githubURL)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("GitHub")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(AppInfo.githubURL.absoluteString)

            Spacer(minLength: 0)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var actionCaption: String {
        switch model.actionMode {
        case .hide:
            return "Hides the frontmost app, in the same spirit as ⌘H. Click its Dock icon again to show it."
        case .minimize:
            return "Minimizes the frontmost app’s windows into the Dock. Click the icon again to restore them."
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin || model.launchAtLoginNeedsApproval },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private var applicationIcon: NSImage {
        // Named images are shared. Leave the size alone and let SwiftUI scale a copy.
        let source = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        return source.copy() as? NSImage ?? source
    }
}
