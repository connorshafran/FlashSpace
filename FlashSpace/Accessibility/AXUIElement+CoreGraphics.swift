//
//  AXUIElement+CoreGraphics.swift
//
//  Created by Wojciech Kulik on 21/03/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit

/// Direct AXUIElement → CGWindowID lookup (private but stable macOS API).
/// Used by most macOS window managers — avoids fragile title/frame heuristics.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ outWindowID: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    /// Returns the CGWindowID directly from the accessibility element.
    /// Falls back to heuristic matching if the direct lookup fails.
    var cgWindowId: CGWindowID? {
        var windowID: CGWindowID = 0
        if _AXUIElementGetWindow(self, &windowID) == .success, windowID != 0 {
            return windowID
        }
        return windowIdHeuristic(onScreenOnly: true)
    }

    /// Like `cgWindowId` but the heuristic fallback searches all windows, including minimized ones.
    var cgWindowIdAll: CGWindowID? {
        var windowID: CGWindowID = 0
        if _AXUIElementGetWindow(self, &windowID) == .success, windowID != 0 {
            return windowID
        }
        return windowIdHeuristic(onScreenOnly: false)
    }

    /// Heuristic fallback: matches by title and frame against the CGWindowList.
    private func windowIdHeuristic(onScreenOnly: Bool) -> CGWindowID? {
        let title = title
        let pid = processId
        let frame = frame
        var fallbackWindowId: CGWindowID?
        var frameBasedFallbackWindowId: CGWindowID?
        let allowedOffset: CGFloat = 0

        let listOption: CGWindowListOption = onScreenOnly ? .optionOnScreenOnly : .optionAll
        if let windowList = CGWindowListCopyWindowInfo(listOption, kCGNullWindowID) as? [[String: Any]] {
            for window in windowList {
                let windowOwnerPID = window[kCGWindowOwnerPID as String] as? pid_t

                if windowOwnerPID == pid {
                    let windowName = window[kCGWindowName as String] as? String
                    let windowNumber = window[kCGWindowNumber as String] as? CGWindowID
                    let windowBoundsDict = window[kCGWindowBounds as String] as? [String: Any]

                    if title == windowName {
                        return windowNumber
                    } else if let frame,
                              let windowBoundsDict,
                              let windowFrame = CGRect(dictionaryRepresentation: windowBoundsDict as CFDictionary),
                              abs(windowFrame.origin.x - frame.origin.x) <= allowedOffset,
                              abs(windowFrame.origin.y - frame.origin.y) <= allowedOffset,
                              abs(windowFrame.size.width - frame.size.width) <= allowedOffset,
                              abs(windowFrame.size.height - frame.size.height) <= allowedOffset {
                        frameBasedFallbackWindowId = windowNumber
                    } else {
                        fallbackWindowId = windowNumber
                    }
                }
            }
        }

        return frameBasedFallbackWindowId ?? fallbackWindowId
    }

    func isBelowAnyOf(_ windows: [AXUIElement]) -> Bool {
        guard let cgWindowId, let frame else { return false }

        let otherWindows = windows.map { (id: $0.cgWindowId, window: $0) }
        let windowsAbove = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, cgWindowId) as? [[String: Any]] ?? [[:]]
        let windowsAboveIds = Set(
            windowsAbove.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        )

        return otherWindows.contains { otherWindowId, otherWindow in
            if let otherWindowId,
               windowsAboveIds.contains(otherWindowId),
               let otherWindowFrame = otherWindow.frame,
               frame.intersects(otherWindowFrame) {
                Logger.log("💡 Window \"\(title ?? "unknown")\" is below \"\(otherWindow.title ?? "unknown")\"")
                return true
            }

            return false
        }
    }
}
