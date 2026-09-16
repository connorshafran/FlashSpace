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
import Combine

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

    private var focusObserver: AXObserver?
    private var focusObserverPid: pid_t?
    private var cancellables = Set<AnyCancellable>()

    init() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter(\.isFinder)
            .sink { [weak self] _ in self?.observeFinderFocus() }
            .store(in: &cancellables)

        observeFinderFocus()
    }

    // MARK: - Public API

    /// Returns the workspace of a Finder window that is currently hidden off-screen.
    func workspaceOfHiddenWindow(_ windowId: CGWindowID) -> WorkspaceID? {
        savedFrames[windowId] != nil ? windowWorkspace[windowId] : nil
    }

    /// Makes the window the one that gets focus when its workspace is activated.
    func focusOnActivation(_ windowId: CGWindowID, in workspaceId: WorkspaceID) {
        lastFocusedWindow[workspaceId] = windowId
        finderWasLastFocused[workspaceId] = true
    }

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
        pruneClosedWindows(of: finder)
        observeFinderFocus() // retry if Finder wasn't ready when it launched

        finder.runWithoutAnimations {
            recoverStrandedWindows(activating: workspaceId, elements: freshElements, onDisplays: onDisplays)
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
        for (wid, element) in freshElements {
            guard savedFrames[wid] == nil else { continue } // skip hidden off-screen windows
            guard windowWorkspace[wid] == nil else { continue } // already tracked

            // Only track windows with a real visible frame (not internal/invisible windows)
            guard let frame = element.frame,
                  frame.width > 50, frame.height > 50,
                  !isOffScreen(frame) else { continue }

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
        var ids: [CGWindowID] = []

        for (wid, element) in elements {
            // Skip hidden off-screen windows
            guard savedFrames[wid] == nil else { continue }

            guard let frame = element.frame,
                  frame.width > 50, frame.height > 50,
                  !isOffScreen(frame),
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
        // savedFrames is kept: windows that couldn't be restored now are
        // recovered by recoverStrandedWindows once they're visible to AX.
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
                windowWorkspace.removeValue(forKey: wid)

                // Windows not visible to AX right now (e.g. on another macOS Space) keep
                // their saved frame, so they are recovered the next time they are seen.
                guard let frame = savedFrames[wid], let element = elements[wid] else { continue }

                Logger.log("Restoring Finder window (id: \(wid)) from deleted workspace")
                restore(element, id: wid, to: frame, onDisplays: nil)
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
                    restore(element, id: wid, to: frame, onDisplays: nil)
                }
            }
        }

        // Frames of windows that couldn't be restored are kept, so a window that
        // wasn't visible to AX (e.g. on another macOS Space) isn't stranded off-screen.
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

    /// Moves a hidden window back on-screen. The saved frame is only dropped once
    /// the window is confirmed visible, so a failed move is retried next time
    /// instead of leaving the window stranded off-screen.
    private func restore(_ element: AXUIElement, id wid: CGWindowID, to frame: CGRect, onDisplays: Set<DisplayName>?) {
        element.setPosition(visibleOrigin(for: frame, onDisplays: onDisplays))

        if let newFrame = element.frame, isOffScreen(newFrame) {
            Logger.log("Failed to restore Finder window (id: \(wid)) - will retry")
            return
        }

        savedFrames.removeValue(forKey: wid)
    }

    /// Drops tracking for Finder windows that no longer exist anywhere (including
    /// other macOS Spaces), so closed windows don't leave stale state behind.
    private func pruneClosedWindows(of finder: NSRunningApplication) {
        guard windowWorkspace.isNotEmpty || savedFrames.isNotEmpty,
              let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        else { return }

        let existingIds = windowList
            .filter { $0[kCGWindowOwnerPID as String] as? pid_t == finder.processIdentifier }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            .asSet

        guard existingIds.isNotEmpty else { return }

        for wid in Set(windowWorkspace.keys).union(savedFrames.keys) where !existingIds.contains(wid) {
            windowWorkspace.removeValue(forKey: wid)
            savedFrames.removeValue(forKey: wid)
        }
        lastFocusedWindow = lastFocusedWindow.filter { existingIds.contains($0.value) }
    }

    /// Repairs Finder windows that ended up off-screen without FlashSpace knowing
    /// where they belong, e.g. after a failed restore, after Finder relaunched and
    /// reopened windows at their hidden position, or after tracking was reset.
    private func recoverStrandedWindows(
        activating workspaceId: WorkspaceID,
        elements: [CGWindowID: AXUIElement],
        onDisplays: Set<DisplayName>?
    ) {
        for (wid, element) in elements {
            guard let frame = element.frame,
                  frame.width > 50, frame.height > 50,
                  !element.isMinimized else { continue }

            let owner = windowWorkspace[wid]

            if let savedFrame = savedFrames[wid] {
                // Hidden, but no longer belongs to any workspace
                guard owner == nil else { continue }

                Logger.log("Recovering untracked hidden Finder window (id: \(wid))")
                restore(element, id: wid, to: savedFrame, onDisplays: onDisplays)
            } else if isOffScreen(frame) {
                if owner == nil || owner == workspaceId {
                    Logger.log("Recovering stranded Finder window (id: \(wid))")
                    element.setPosition(visibleOrigin(for: frame, onDisplays: onDisplays))
                } else {
                    // Belongs to another workspace: keep it hidden, but remember
                    // a visible frame to restore it to later.
                    let origin = visibleOrigin(for: frame, onDisplays: onDisplays)
                    savedFrames[wid] = CGRect(origin: origin, size: frame.size)
                }
            }
        }
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
            restore(element, id: wid, to: originalFrame, onDisplays: onDisplays)
        }
    }

    private func hideWindowsNotIn(
        _ workspaceId: WorkspaceID,
        elements: [CGWindowID: AXUIElement],
        onDisplays: Set<DisplayName>? = nil
    ) {
        for (wid, element) in elements {
            // Only hide windows tracked to a DIFFERENT workspace
            guard let trackedWs = windowWorkspace[wid], trackedWs != workspaceId else { continue }

            guard let frame = element.frame else { continue }

            // Already hidden. macOS may have moved it back on-screen (e.g. after a
            // display change), in which case hide it again but keep the saved frame.
            if savedFrames[wid] != nil {
                guard !isOffScreen(frame) else { continue }

                Logger.log("Re-hiding Finder window (id: \(wid)) that came back on-screen")
                element.setPosition(hiddenPosition(for: frame))
                continue
            }

            // When isolating displays, only hide windows on the target displays
            if let displays = onDisplays,
               let display = frame.getDisplay(),
               !displays.contains(display) {
                continue
            }

            // Off-screen without a saved frame is handled by recoverStrandedWindows
            guard !isOffScreen(frame) else { continue }

            let position = hiddenPosition(for: frame)
            Logger.log("Hiding Finder window \"\(element.title ?? "untitled")\" (id: \(wid)) to \(position)")
            savedFrames[wid] = frame
            element.setPosition(position)
        }
    }
}

// MARK: - Finder Focus Observer
extension FinderWindowManager {
    /// Posts `.finderFocusedWindowChanged` whenever Finder's focused window changes.
    /// Unlike app activation, this also fires while Finder is already frontmost,
    /// e.g. when opening a folder that is already open in another window.
    private func observeFinderFocus() {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder),
              finder.processIdentifier != focusObserverPid else { return }

        if let focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .defaultMode)
            self.focusObserver = nil
        }

        let callback: AXObserverCallback = { _, _, _, _ in
            NotificationCenter.default.post(name: .finderFocusedWindowChanged, object: nil)
        }

        var observer: AXObserver?
        guard AXObserverCreate(finder.processIdentifier, callback, &observer) == .success,
              let observer else { return }

        let finderElement = AXUIElementCreateApplication(finder.processIdentifier)
        let notification = kAXFocusedWindowChangedNotification as CFString
        guard AXObserverAddNotification(observer, finderElement, notification, nil) == .success else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        focusObserver = observer
        focusObserverPid = finder.processIdentifier
    }
}

// MARK: - Window Geometry
extension FinderWindowManager {
    /// Generates an off-screen position at the right edge of the rightmost display.
    /// The y coordinate is kept within that display, so macOS doesn't consider the
    /// window lost and move it back on-screen.
    private func hiddenPosition(for currentFrame: CGRect) -> CGPoint {
        guard let rightmost = NSScreen.screens.map(\.normalizedFrame).max(by: { $0.maxX < $1.maxX }) else {
            return CGPoint(x: currentFrame.maxX + 10000, y: currentFrame.origin.y)
        }

        let y = currentFrame.origin.y + CGFloat.random(in: 1...100)
        return CGPoint(
            x: rightmost.maxX - 1,
            y: max(rightmost.minY + 50, min(y, rightmost.maxY - 100))
        )
    }

    /// A window is off-screen when no display shows a meaningful part of it.
    private func isOffScreen(_ frame: CGRect) -> Bool {
        !NSScreen.screens.contains { screen in
            let visible = screen.normalizedFrame.intersection(frame)
            return !visible.isNull && visible.width >= 40 && visible.height >= 40
        }
    }

    /// Returns the frame's origin if it's visible, otherwise an origin that centers
    /// the window on the target display (e.g. when its display was disconnected).
    private func visibleOrigin(for frame: CGRect, onDisplays: Set<DisplayName>?) -> CGPoint {
        guard isOffScreen(frame) else { return frame.origin }

        let screen = NSScreen.screen(onDisplays?.first) ?? NSScreen.main ?? NSScreen.screens.first
        guard let bounds = screen?.normalizedFrame else { return frame.origin }

        return CGPoint(
            x: bounds.midX - frame.width / 2,
            y: max(bounds.minY, bounds.midY - frame.height / 2)
        )
    }
}
