//
//  NSRunningApplication+Apps.swift
//
//  Created by Wojciech Kulik on 12/07/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit

extension NSRunningApplication {
    var isFinder: Bool { bundleIdentifier == "com.apple.finder" }
    var isPython: Bool { bundleIdentifier == "org.python.python" }
    var isOrion: Bool { bundleIdentifier == "com.kagi.kagimacOS" }

    /// Returns true if Finder is active but the user is interacting with the
    /// desktop (e.g. clicked the wallpaper or used "Show Desktop" hot corner)
    /// rather than focusing an actual Finder window.
    var isFinderDesktopInteraction: Bool {
        guard isFinder else { return false }

        // When the user clicks the desktop, Finder activates but
        // focusedWindow is nil (the desktop is not a regular AXWindow).
        return focusedWindow == nil
    }
}
