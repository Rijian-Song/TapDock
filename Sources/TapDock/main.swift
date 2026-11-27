// TapDock
// Copyright (c) 2026 Rijian Song
// Copyright (c) 2026 L2M Group Ltd.
// Released under the MIT License. See LICENSE.

import Cocoa

// A direct swiftc build does not bootstrap AppKit from an @main entry.
// NSApplication.run() is what delivers applicationDidFinishLaunching.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
