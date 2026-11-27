// TapDock
// Copyright (c) 2026 Rijian Song
// Copyright (c) 2026 L2M Group Ltd.
// Released under the MIT License. See LICENSE.

import Cocoa

// A direct swiftc build does not bootstrap AppKit from an @main entry.
// NSApplication.run() is what delivers applicationDidFinishLaunching.
//
// Under -swift-version 5 the top-level entry is nonisolated, while AppDelegate
// is @MainActor. The process is already on the main thread here.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
