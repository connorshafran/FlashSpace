//
//  WorkspaceHotKeys.swift
//
//  Created by Wojciech Kulik on 08/02/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit

final class WorkspaceHotKeys {
    private let workspaceManager: WorkspaceManager
    private let workspaceRepository: WorkspaceRepository
    private let workspaceSettings: WorkspaceSettings
    private let floatingAppsSettings: FloatingAppsSettings

    init(
        workspaceManager: WorkspaceManager,
        workspaceRepository: WorkspaceRepository,
        settingsRepository: SettingsRepository
    ) {
        self.workspaceManager = workspaceManager
        self.workspaceRepository = workspaceRepository
        self.workspaceSettings = settingsRepository.workspaceSettings
        self.floatingAppsSettings = settingsRepository.floatingAppsSettings
    }

    func getHotKeys() -> [RecordedHotKey] {
        let hotKeys = [
            getAssignVisibleAppsHotKey(),
            getAssignAppHotKey(for: nil),
            getUnassignAppHotKey(),
            getToggleAssignmentHotKey(),
            getShowUnassignedAppsHotKey(),
            getHideUnassignedAppsHotKey(),
            getHideAllAppsHotKey(),
            getRecentWorkspaceHotKey(),
            getCycleWorkspacesHotKey(next: false),
            getCycleWorkspacesHotKey(next: true),
            getCycleWindowsHotKey(next: true),
            getCycleWindowsHotKey(next: false)
        ] +
            workspaceRepository.workspaces
            .flatMap { [getActivateHotKey(for: $0), getAssignAppHotKey(for: $0)] }

        return hotKeys.compactMap(\.self)
    }

    private func getActivateHotKey(for workspace: Workspace) -> RecordedHotKey? {
        guard let shortcut = workspace.activateShortcut else { return nil }

        let action = { [weak self] in
            guard let self, let updatedWorkspace = workspaceRepository.findWorkspace(with: workspace.id) else { return }

            if workspaceSettings.showRecentWorkspaceWhenActivatedTwice,
               let display = DisplayName.currentOptional,
               workspaceManager.activeWorkspace[display]?.id == updatedWorkspace.id,
               let recentWorkspace = workspaceManager.mostRecentWorkspace[display] {
                return workspaceManager.activateWorkspace(recentWorkspace, setFocus: true)
            }

            if updatedWorkspace.isDynamic, updatedWorkspace.displays.isEmpty,
               workspace.apps.isEmpty || updatedWorkspace.openAppsOnActivation != true {
                Toast.showWith(
                    icon: "square.stack.3d.up",
                    message: "\(workspace.name) - No Running Apps To Show",
                    textColor: .gray
                )
                return
            }

            workspaceManager.activateWorkspace(updatedWorkspace, setFocus: true)
        }

        return RecordedHotKey(
            name: .activateWorkspace(workspace.id),
            hotKey: shortcut,
            action: action
        )
    }

    private func getAssignVisibleAppsHotKey() -> RecordedHotKey? {
        guard let shortcut = workspaceSettings.assignVisibleApps else { return nil }

        return RecordedHotKey(
            name: .assignVisibleApps,
            hotKey: shortcut,
            action: { [weak self] in self?.assignVisibleApps() }
        )
    }

    private func getAssignAppHotKey(for workspace: Workspace?) -> RecordedHotKey? {
        let shortcut = workspace == nil
            ? workspaceSettings.assignFocusedApp
            : workspace?.assignAppShortcut

        guard let shortcut else { return nil }

        let name: HotKeyName = if let workspace {
            .assignAppToWorkspace(workspace.id)
        } else {
            .assignFocusedApp
        }

        return RecordedHotKey(
            name: name,
            hotKey: shortcut,
            action: { [weak self] in self?.assignApp(to: workspace) }
        )
    }

    private func getUnassignAppHotKey() -> RecordedHotKey? {
        guard let shortcut = workspaceSettings.unassignFocusedApp else { return nil }

        return RecordedHotKey(
            name: .unassignFocusedApp,
            hotKey: shortcut,
            action: { [weak self] in self?.unassignApp() }
        )
    }

    private func getToggleAssignmentHotKey() -> RecordedHotKey? {
        guard let shortcut = workspaceSettings.toggleFocusedAppAssignment else { return nil }

        let action = { [weak self] in
            guard let self, let activeApp = NSWorkspace.shared.frontmostApplication else { return }

            let macApp = activeApp.toMacApp
            let isAssigned = workspaceRepository.workspaces.flatMap(\.apps).containsApp(activeApp) ||
                workspaceManager.hasTemporaryAssignment(for: macApp)

            if isAssigned {
                unassignApp()
            } else {
                assignApp(to: nil)
            }
        }

        return RecordedHotKey(
            name: .toggleFocusedAppAssignment,
            hotKey: shortcut,
            action: action
        )
    }

    private func getShowUnassignedAppsHotKey() -> RecordedHotKey? {
        guard let shortcut = workspaceSettings.showUnassignedApps else { return nil }

        let action = { [weak self] in
            guard let self else { return }

            workspaceManager.showUnassignedApps()
        }

        return RecordedHotKey(
            name: .showUnassignedApps,
            hotKey: shortcut,
            action: action
        )
    }

    private func getHideUnassignedAppsHotKey() -> RecordedHotKey? {
        guard let shortcut = workspaceSettings.hideUnassignedApps else { return nil }

        let action = { [weak self] in
            guard let self else { return }

            workspaceManager.hideUnassignedApps()
        }

        return RecordedHotKey(
            name: .hideUnassignedApps,
            hotKey: shortcut,
            action: action
        )
    }

    private func getHideAllAppsHotKey() -> RecordedHotKey? {
        guard let shortcut = workspaceSettings.hideAllApps else { return nil }

        let action = { [weak self] in
            guard let self else { return }

            workspaceManager.hideAll()
        }

        return RecordedHotKey(
            name: .hideAllApps,
            hotKey: shortcut,
            action: action
        )
    }

    private func getCycleWorkspacesHotKey(next: Bool) -> RecordedHotKey? {
        guard let shortcut = next
            ? workspaceSettings.switchToNextWorkspace
            : workspaceSettings.switchToPreviousWorkspace
        else { return nil }

        let action: () -> () = { [weak self] in
            guard let self else { return }

            workspaceManager.activateWorkspace(
                next: next,
                skipEmpty: workspaceSettings.skipEmptyWorkspacesOnSwitch,
                loop: workspaceSettings.loopWorkspaces
            )
        }

        return RecordedHotKey(
            name: next ? .nextWorkspace : .previousWorkspace,
            hotKey: shortcut,
            action: action
        )
    }

    private func getRecentWorkspaceHotKey() -> RecordedHotKey? {
        guard let shortcut = workspaceSettings.switchToRecentWorkspace else { return nil }

        let action: () -> () = { [weak self] in
            self?.workspaceManager.activateRecentWorkspace()
        }

        return RecordedHotKey(
            name: .recentWorkspace,
            hotKey: shortcut,
            action: action
        )
    }

    private func getCycleWindowsHotKey(next: Bool) -> RecordedHotKey? {
        let shortcut = next
            ? workspaceSettings.cycleWindowsForward
            : workspaceSettings.cycleWindowsBackward

        guard let shortcut else { return nil }

        let action: () -> () = { [weak self] in
            self?.cycleWindows(next: next)
        }

        return RecordedHotKey(
            name: next ? .cycleWindowsForward : .cycleWindowsBackward,
            hotKey: shortcut,
            action: action
        )
    }
}

extension WorkspaceHotKeys {
    private func assignApp(to workspace: Workspace?) {
        guard let activeApp = NSWorkspace.shared.frontmostApplication else { return }
        guard let appName = activeApp.localizedName else { return }
        guard activeApp.activationPolicy == .regular else {
            Alert.showOkAlert(
                title: appName,
                message: "This application is an agent (runs in background) and cannot be managed by FlashSpace."
            )
            return
        }

        guard let workspace = workspace ?? workspaceManager.activeWorkspace[activeApp.display ?? ""] else {
            Alert.showOkAlert(
                title: "Error",
                message: "No workspace is active on the current display."
            )
            return
        }

        // Finder is managed per-window: assign only the focused Finder window
        if activeApp.isFinder {
            let finderWindowManager = AppDependencies.shared.finderWindowManager
            finderWindowManager.assignFocusedFinderWindow(to: workspace.id)

            if let updatedWorkspace = workspaceRepository.findWorkspace(with: workspace.id) {
                workspaceManager.activateWorkspace(updatedWorkspace, setFocus: true)
            }

            Toast.showWith(
                icon: "square.stack.3d.up",
                message: "Finder Window - Moved To \(workspace.name)",
                textColor: .positive
            )
            return
        }

        guard let updatedWorkspace = workspaceRepository.findWorkspace(with: workspace.id) else { return }

        workspaceManager.moveAppToWorkspace(activeApp.toMacApp, to: updatedWorkspace)

        if !workspace.isDynamic {
            activeApp.centerApp(display: workspace.display)
        }

        Toast.showWith(
            icon: "square.stack.3d.up",
            message: "\(appName) - Moved To \(workspace.name)",
            textColor: .positive
        )
    }

    private func assignVisibleApps() {
        guard let display = DisplayName.currentOptional else { return }
        guard let workspace = workspaceManager.activeWorkspace[display] else {
            Alert.showOkAlert(
                title: "Error",
                message: "No workspace is active on the current display."
            )
            return
        }

        let visibleApps = NSWorkspace.shared.runningApplications
            .regularVisibleApps(onDisplays: workspace.displays, excluding: floatingAppsSettings.floatingApps)

        for app in visibleApps {
            workspaceManager.temporarilyAssignApp(app.toMacApp, to: workspace)
        }

        Toast.showWith(
            icon: "square.stack.3d.up",
            message: "Moved \(visibleApps.count) App(s) To \(workspace.name)",
            textColor: .positive
        )
    }

    private func unassignApp() {
        guard let activeApp = NSWorkspace.shared.frontmostApplication else { return }
        guard let appName = activeApp.localizedName else { return }

        let macApp = activeApp.toMacApp
        workspaceManager.removeTemporaryApp(macApp)
        workspaceManager.removeBorrowedApp(macApp)

        Toast.showWith(
            icon: "square.stack.3d.up.slash",
            message: "\(appName) - Removed From Workspace",
            textColor: .negative
        )

        activeApp.hide()
    }

    /// An item in the window cycle: either a regular app or a specific Finder window.
    private enum CycleItem: Equatable {
        case app(bundleId: String)
        case finderWindow(windowId: CGWindowID)
    }

    private func cycleWindows(next: Bool) {
        // Defer all work to a normal main-queue block to escape the
        // Carbon hotkey callback context, which appears to crash/deadlock
        // when accessing certain objects.
        DispatchQueue.main.async { [weak self] in
            self?.doCycleWindows(next: next)
        }
    }

    private func doCycleWindows(next: Bool) {
        guard let currentDisplay = DisplayName.currentOptional else { return }

        let isolating = workspaceSettings.isolateSecondaryDisplays && NSScreen.screens.count > 1
        let workspace = workspaceManager.activeWorkspace[currentDisplay]

        // Without isolation, require an active workspace (existing behavior)
        guard isolating || workspace != nil else { return }

        let finderBundleId = "com.apple.finder"
        let finderWindowManager = AppDependencies.shared.finderWindowManager

        // When isolating, cycle only on the current display
        let cycleDisplays: Set<DisplayName> = isolating
            ? [currentDisplay]
            : (workspace?.displays ?? [currentDisplay])

        // Get Finder windows and fresh elements
        let freshFinderElements: [CGWindowID: AXUIElement]
        let finderWindowIds: [CGWindowID]

        if isolating {
            // Display-scoped: get only Finder windows visible on the current display
            let result = finderWindowManager.visibleFinderWindows(on: cycleDisplays)
            finderWindowIds = result.ids
            freshFinderElements = result.elements
        } else if let ws = workspace {
            // Workspace-scoped (existing behavior)
            freshFinderElements = finderWindowManager.refreshTrackedWindows(for: ws.id)
            finderWindowIds = finderWindowManager.trackedWindowIds(for: ws.id)
        } else {
            return
        }

        var items: [CycleItem] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isHidden,
                  let bundleId = app.bundleIdentifier else { continue }
            if bundleId == finderBundleId { continue }
            guard app.isOnAnyDisplay(cycleDisplays) else { continue }

            let item = CycleItem.app(bundleId: bundleId)
            if !items.contains(item) { items.append(item) }
        }

        for wid in finderWindowIds {
            items.append(.finderWindow(windowId: wid))
        }

        guard items.count > 1 else { return }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let currentBundleId = frontmostApp?.bundleIdentifier
        let currentIndex: Int
        if currentBundleId == finderBundleId {
            // Query Finder's actual focused window for reliable current position.
            // lastFocusedWindowId may be stale or nil (e.g., secondary display with no workspace).
            let focusedWid = frontmostApp?.focusedWindow?.cgWindowId
            if let focusedWid, let idx = items.firstIndex(of: .finderWindow(windowId: focusedWid)) {
                currentIndex = idx
            } else {
                let lastWid = workspace.flatMap { finderWindowManager.lastFocusedWindowId(for: $0.id) }
                if let lastWid, let idx = items.firstIndex(of: .finderWindow(windowId: lastWid)) {
                    currentIndex = idx
                } else if let idx = items.firstIndex(where: { if case .finderWindow = $0 { return true }; return false }) {
                    currentIndex = idx
                } else {
                    currentIndex = 0
                }
            }
        } else {
            currentIndex = currentBundleId
                .flatMap { bid in items.firstIndex(of: .app(bundleId: bid)) } ?? 0
        }

        let nextIndex: Int
        if next {
            nextIndex = (currentIndex + 1) % items.count
        } else {
            nextIndex = (currentIndex - 1 + items.count) % items.count
        }

        switch items[nextIndex] {
        case .app(let bundleId):
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == bundleId }?
                .activate()
        case .finderWindow(let windowId):
            finderWindowManager.focusFinderWindow(windowId, elements: freshFinderElements)
        }
    }
}
