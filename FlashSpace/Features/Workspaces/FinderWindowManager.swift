//
//  FinderWindowManager.swift
//
//  Manages individual Finder windows per workspace, allowing each
//  workspace to have its own set of Finder windows rather than
//  treating Finder as a single monolithic app.
//
//  Uses CGWindowID (a stable integer) to track windows across
//  AXUIElement lookups, and off-screen positioning for instant
//  per-window hiding (matching FlashSpace's normal hide speed).
//

import AppKit

final class FinderWindowManager {
    /// Which workspace each tracked Finder window belongs to.
    private var windowWorkspace: [CGWindowID: WorkspaceID] = [:]

    /// Saved original frames of windows we've moved off-screen, keyed by CGWindowID.
    private var savedFrames: [CGWindowID: CGRect] = [:]

    /// The last focused Finder window in each workspace.
    private var lastFocusedWindow: [WorkspaceID: CGWindowID] = [:]

    /// Whether Finder was the very last thing focused in each workspace
    /// (as opposed to another app being focused after the Finder window).
    private(set) var finderWasLastFocused: [WorkspaceID: Bool] = [:]

    // MARK: - Public API

    /// Called when a Finder window gains focus while a workspace is active.
    /// Associates the focused window with the given workspace.
    /// Skips windows that are currently hidden (off-screen) to avoid
    /// re-tracking them to the wrong workspace on switch.
    func trackFocusedFinderWindow(in workspaceId: WorkspaceID) {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder),
              let focused = finder.focusedWindow,
              let windowId = focused.cgWindowId else { return }

        // Don't re-track windows we've hidden off-screen
        guard savedFrames[windowId] == nil else { return }

        let previous = windowWorkspace[windowId]
        windowWorkspace[windowId] = workspaceId
        lastFocusedWindow[workspaceId] = windowId
        finderWasLastFocused[workspaceId] = true

        if previous != workspaceId {
            Logger.log("Finder window \"\(focused.title ?? "untitled")\" (id: \(windowId)) tracked in workspace")
        }
    }

    /// Called when a non-Finder app gains focus, so we know Finder is no longer
    /// the last focused thing in the active workspace.
    func clearFinderFocus(for workspaceId: WorkspaceID) {
        finderWasLastFocused[workspaceId] = false
    }

    /// Tracks all visible (not hidden) Finder windows to the given workspace.
    /// Called before a workspace switch to capture all windows the user has open,
    /// not just the focused one.
    func trackAllVisibleFinderWindows(in workspaceId: WorkspaceID, onDisplays: Set<DisplayName>? = nil) {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) else { return }

        // If Finder is the frontmost app, record that it was last focused
        // in this workspace.
        if NSWorkspace.shared.frontmostApplication?.isFinder == true,
           let focused = finder.focusedWindow,
           let focusedId = focused.cgWindowId,
           savedFrames[focusedId] == nil {
            // When isolating displays, only track if the focused window is on one of the target displays
            if let displays = onDisplays {
                if let frame = focused.frame, let display = frame.getDisplay(), displays.contains(display) {
                    lastFocusedWindow[workspaceId] = focusedId
                    finderWasLastFocused[workspaceId] = true
                }
            } else {
                lastFocusedWindow[workspaceId] = focusedId
                finderWasLastFocused[workspaceId] = true
            }
        }

        for element in finder.allWindowElements {
            guard let wid = element.cgWindowId else { continue }

            // Don't re-track windows we've hidden off-screen
            guard savedFrames[wid] == nil else { continue }

            // When isolating displays, only track windows on the target displays
            if let displays = onDisplays {
                guard let frame = element.frame, let display = frame.getDisplay(), displays.contains(display) else {
                    continue
                }
            }

            // Don't steal windows already tracked to another workspace
            guard windowWorkspace[wid] == nil || windowWorkspace[wid] == workspaceId else { continue }

            if windowWorkspace[wid] != workspaceId {
                Logger.log("Finder window \"\(element.title ?? "untitled")\" (id: \(wid)) tracked in workspace (bulk)")
            }
            windowWorkspace[wid] = workspaceId
        }
    }

    /// Reassigns the currently focused Finder window to the given workspace.
    /// Used by the "Assign Focused App" hotkey for per-window Finder management.
    func assignFocusedFinderWindow(to workspaceId: WorkspaceID) {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder),
              let focused = finder.focusedWindow,
              let windowId = focused.cgWindowId else { return }

        windowWorkspace[windowId] = workspaceId
        Logger.log("Finder window \"\(focused.title ?? "untitled")\" (id: \(windowId)) assigned to workspace")
    }

    /// Shows Finder windows belonging to the given workspace and hides
    /// Finder windows belonging to other workspaces.
    /// Called during workspace activation.
    func activateWorkspace(_ workspaceId: WorkspaceID, onDisplays: Set<DisplayName>? = nil) {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) else { return }

        // Refresh AXUIElement references from current window list.
        // References go stale when Finder is raised/shown by FlashSpace.
        let freshElements = refreshedWindowElements(for: finder)

        finder.runWithoutAnimations {
            restoreWindows(for: workspaceId, elements: freshElements, onDisplays: onDisplays)
            hideWindowsNotIn(workspaceId, elements: freshElements, onDisplays: onDisplays)
        }

        // If Finder was the last focused thing in this workspace,
        // raise the specific window and activate Finder.
        // In isolation mode, skip if the window is on a different display
        // to avoid raising Finder globally (which disrupts other displays).
        if finderWasLastFocused[workspaceId] == true,
           let lastWid = lastFocusedWindow[workspaceId],
           let element = freshElements[lastWid] {
            let windowOnTargetDisplay: Bool = {
                guard let displays = onDisplays, let frame = element.frame,
                      let display = frame.getDisplay() else { return true }
                return displays.contains(display)
            }()

            if windowOnTargetDisplay {
                Logger.log("Focusing last Finder window (id: \(lastWid)) in workspace")
                element.focus()
                finder.activate()
            }
        }
    }

    /// Raises a specific Finder window by CGWindowID using a fresh AXUIElement.
    /// Must be called from a non-Carbon-callback context (e.g. DispatchQueue.main.async).
    func focusFinderWindow(_ windowId: CGWindowID, elements: [CGWindowID: AXUIElement]) {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) else { return }

        if let element = elements[windowId] {
            Logger.log("Focusing Finder window (id: \(windowId)) via AXRaise")
            element.focus()
            finder.activate()

            // Update tracking directly — the didActivateApplicationNotification
            // won't fire when cycling between Finder windows because
            // .removeDuplicates() filters consecutive Finder activations.
            if let ws = windowWorkspace[windowId] {
                lastFocusedWindow[ws] = windowId
                finderWasLastFocused[ws] = true
            }
        }
    }

    /// Queries Finder's current windows and updates tracking for the given workspace:
    /// - Discovers and tracks new visible windows not yet tracked
    /// - Removes tracked windows that no longer exist (closed by user)
    /// Returns the fresh elements map for reuse by the caller.
    /// Must be called from a non-Carbon-callback context.
    @discardableResult
    func refreshTrackedWindows(for workspaceId: WorkspaceID) -> [CGWindowID: AXUIElement] {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) else { return [:] }

        let freshElements = refreshedWindowElements(for: finder)
        let existingIds = Set(freshElements.keys)

        // Track new visible windows not yet assigned to any workspace.
        // Filter out internal/invisible Finder windows (e.g. desktop, utility panels)
        // by requiring a reasonable visible frame.
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 2000
        for (wid, element) in freshElements {
            guard savedFrames[wid] == nil else { continue } // skip hidden off-screen windows
            guard windowWorkspace[wid] == nil else { continue } // already tracked

            // Only track windows with a real visible frame (not internal/invisible windows)
            guard let frame = element.frame,
                  frame.width > 50, frame.height > 50,
                  frame.origin.x < maxX - 10 else { continue }

            windowWorkspace[wid] = workspaceId
            Logger.log("Finder window \"\(element.title ?? "untitled")\" (id: \(wid)) tracked in workspace (cycle refresh)")
        }

        // Remove windows tracked to this workspace that no longer exist
        for (wid, ws) in windowWorkspace where ws == workspaceId {
            guard savedFrames[wid] == nil else { continue } // hidden windows may not appear in freshElements
            if !existingIds.contains(wid) {
                Logger.log("Finder window (id: \(wid)) no longer exists — removing from tracking")
                windowWorkspace.removeValue(forKey: wid)
                if lastFocusedWindow[ws] == wid {
                    lastFocusedWindow.removeValue(forKey: ws)
                }
            }
        }

        return freshElements
    }

    /// Returns the CGWindowIDs of Finder windows tracked to the given workspace.
    /// Sorted for stable cycle order.
    func trackedWindowIds(for workspaceId: WorkspaceID) -> [CGWindowID] {
        windowWorkspace.compactMap { wid, ws in ws == workspaceId ? wid : nil }.sorted()
    }

    /// Returns the last focused Finder window in the given workspace, if any.
    func lastFocusedWindowId(for workspaceId: WorkspaceID) -> CGWindowID? {
        lastFocusedWindow[workspaceId]
    }

    /// Returns visible Finder window IDs on the given displays, along with fresh AXUIElement references.
    /// Does not modify tracking state. Used for display-scoped cycling.
    func visibleFinderWindows(on displays: Set<DisplayName>) -> (ids: [CGWindowID], elements: [CGWindowID: AXUIElement]) {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) else { return ([], [:]) }

        let elements = refreshedWindowElements(for: finder)
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 2000
        var ids: [CGWindowID] = []

        for (wid, element) in elements {
            // Skip hidden off-screen windows
            guard savedFrames[wid] == nil else { continue }

            guard let frame = element.frame,
                  frame.width > 50, frame.height > 50,
                  frame.origin.x < maxX - 10,
                  let display = frame.getDisplay(),
                  displays.contains(display) else { continue }

            ids.append(wid)
        }

        // Sort for stable cycle order (dictionary iteration is non-deterministic)
        ids.sort()

        return (ids, elements)
    }

    /// Returns (windowId, title) pairs for all Finder windows tracked to the given workspace.
    func windowTitles(for workspaceId: WorkspaceID) -> [(id: CGWindowID, title: String)] {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) else { return [] }

        let elements = refreshedWindowElements(for: finder)
        return trackedWindowIds(for: workspaceId).compactMap { wid in
            guard let element = elements[wid] else { return nil }
            return (id: wid, title: element.title ?? "Finder")
        }
    }

    /// Reassigns a Finder window from one workspace to another.
    func moveFinderWindow(_ windowId: CGWindowID, to workspaceId: WorkspaceID) {
        windowWorkspace[windowId] = workspaceId
        Logger.log("Finder window (id: \(windowId)) moved to workspace via Space Control")
    }

    /// Clears all tracking state (e.g. on profile change).
    func reset() {
        restoreAllWindows()
        windowWorkspace = [:]
        savedFrames = [:]
        lastFocusedWindow = [:]
        finderWasLastFocused = [:]
    }

    /// Restores hidden Finder windows whose workspace no longer exists in the given set.
    /// Called when workspaces change to prevent stranding windows off-screen.
    func restoreWindowsNotIn(validWorkspaces: Set<WorkspaceID>) {
        let widsToRestore = savedFrames.keys.filter { wid in
            guard let ws = windowWorkspace[wid] else { return true }
            return !validWorkspaces.contains(ws)
        }

        guard widsToRestore.isNotEmpty,
              let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) else { return }

        let elements = refreshedWindowElements(for: finder)

        finder.runWithoutAnimations {
            for wid in widsToRestore {
                if let frame = savedFrames[wid], let element = elements[wid] {
                    Logger.log("Restoring Finder window (id: \(wid)) from deleted workspace")
                    element.setPosition(frame.origin)
                }
                savedFrames.removeValue(forKey: wid)
                windowWorkspace.removeValue(forKey: wid)
            }
        }

        // Clean up tracking state for deleted workspaces
        let deletedWorkspaces = Set(lastFocusedWindow.keys).subtracting(validWorkspaces)
        for wsId in deletedWorkspaces {
            lastFocusedWindow.removeValue(forKey: wsId)
            finderWasLastFocused.removeValue(forKey: wsId)
        }
    }

    /// Restores all hidden Finder windows to their original positions.
    /// Called during cleanup (e.g. app quit, hideAll).
    func restoreAllWindows() {
        guard savedFrames.isNotEmpty,
              let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) else { return }

        let elements = refreshedWindowElements(for: finder)

        finder.runWithoutAnimations {
            for (wid, element) in elements {
                if let frame = savedFrames[wid] {
                    Logger.log("Restoring Finder window \"\(element.title ?? "untitled")\" (id: \(wid))")
                    element.setPosition(frame.origin)
                }
            }
        }

        savedFrames = [:]
    }

    // MARK: - Private

    /// Builds a fresh CGWindowID → AXUIElement mapping from Finder's current window list.
    private func refreshedWindowElements(for finder: NSRunningApplication) -> [CGWindowID: AXUIElement] {
        var elements: [CGWindowID: AXUIElement] = [:]
        for element in finder.allWindowElements {
            if let wid = element.cgWindowId {
                elements[wid] = element
            }
        }
        Logger.log("refreshedWindowElements: found \(elements.count) windows: \(elements.keys.sorted())")
        return elements
    }

    /// Generates an off-screen position based on the window's current position.
    private func hiddenPosition(for currentFrame: CGRect) -> CGPoint {
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 2000
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? 1200
        let x = maxX - 1
        let y = max(50, min(currentFrame.origin.y + CGFloat.random(in: 1...100), maxY - 100))
        return CGPoint(x: x, y: y)
    }

    private func restoreWindows(
        for workspaceId: WorkspaceID,
        elements: [CGWindowID: AXUIElement],
        onDisplays: Set<DisplayName>? = nil
    ) {
        for (wid, element) in elements {
            guard windowWorkspace[wid] == workspaceId,
                  let originalFrame = savedFrames[wid] else { continue }

            // When isolating displays, only restore windows whose saved position is on the target displays
            if let displays = onDisplays,
               let display = originalFrame.getDisplay(),
               !displays.contains(display) {
                continue
            }

            Logger.log("Restoring Finder window \"\(element.title ?? "untitled")\" (id: \(wid)) to \(originalFrame.origin)")
            element.setPosition(originalFrame.origin)
            savedFrames.removeValue(forKey: wid)
        }
    }

    private func hideWindowsNotIn(
        _ workspaceId: WorkspaceID,
        elements: [CGWindowID: AXUIElement],
        onDisplays: Set<DisplayName>? = nil
    ) {
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 2000

        for (wid, element) in elements {
            // Skip windows already hidden
            guard savedFrames[wid] == nil else { continue }

            // Only hide windows tracked to a DIFFERENT workspace
            guard let trackedWs = windowWorkspace[wid], trackedWs != workspaceId else { continue }

            guard let frame = element.frame else { continue }

            // When isolating displays, only hide windows on the target displays
            if let displays = onDisplays,
               let display = frame.getDisplay(),
               !displays.contains(display) {
                continue
            }

            // Don't save the frame if it's already at a hidden position
            // (this can happen if a previous restore failed with a stale AXUIElement)
            guard frame.origin.x < maxX - 10 else {
                Logger.log("Skipping hide for Finder window (id: \(wid)) — already at hidden position \(frame.origin)")
                continue
            }

            let position = hiddenPosition(for: frame)
            Logger.log("Hiding Finder window \"\(element.title ?? "untitled")\" (id: \(wid)) to \(position)")
            savedFrames[wid] = frame
            element.setPosition(position)
        }
    }
}
