//
//  FocusedWindowTracker.swift
//
//  Created by Wojciech Kulik on 20/01/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit
import Combine

final class FocusedWindowTracker {
    private var cancellables = Set<AnyCancellable>()
    private var lastFocusedFinderWindow: CGWindowID?

    private let workspaceRepository: WorkspaceRepository
    private let workspaceManager: WorkspaceManager
    private let settingsRepository: SettingsRepository
    private let pictureInPictureManager: PictureInPictureManager

    init(
        workspaceRepository: WorkspaceRepository,
        workspaceManager: WorkspaceManager,
        settingsRepository: SettingsRepository,
        pictureInPictureManager: PictureInPictureManager
    ) {
        self.workspaceRepository = workspaceRepository
        self.workspaceManager = workspaceManager
        self.settingsRepository = settingsRepository
        self.pictureInPictureManager = pictureInPictureManager

        activateWorkspaceForFocusedApp(force: true)
    }

    func startTracking() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.activationPolicy == .regular }
            .removeDuplicates()
            .sink { [weak self] app in
                self?.applicationActivated(app)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .finderFocusedWindowChanged)
            .sink { [weak self] _ in self?.finderFocusedWindowChanged() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .profileChanged)
            .sink { [weak self] _ in self?.activateWorkspaceForFocusedApp() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .delay(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.activateWorkspaceForFocusedApp(force: true) }
            .store(in: &cancellables)
    }

    func stopTracking() {
        cancellables.removeAll()
    }

    private func applicationActivated(_ app: NSRunningApplication, afterSettling: Bool = false) {
        // Ignore Finder desktop interactions (clicking wallpaper, Show Desktop, etc.)
        guard !app.isFinderDesktopInteraction else { return }

        // Activations right after a workspace switch are often side effects of the
        // switch itself, e.g. hiding the frontmost app makes macOS activate another
        // app that is about to be hidden too. Handling them would borrow or assign
        // that app to the new workspace (so it never gets hidden) or switch back.
        // Re-check once the switch has settled and only continue if the app is
        // still frontmost and visible.
        let settleDelay = 0.4
        if !afterSettling, Date().timeIntervalSince(workspaceManager.lastWorkspaceActivation) < settleDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
                guard let self, cancellables.isNotEmpty else { return }
                guard NSWorkspace.shared.frontmostApplication == app, !app.isHidden else {
                    return Logger.log("Ignoring transient activation: \(app.localizedName ?? "")")
                }

                applicationActivated(app, afterSettling: true)
            }
            return
        }

        if app.isFinder {
            handleFinderWindowFocus(app)
        } else {
            clearFinderFocusForActiveWorkspace()
            temporarilyAssignAppIfNeeded(app)
            activeApplicationChanged(app, force: false)
            autoAssignAppToWorkspaceIfNeeded(app)
        }
    }

    private func activateWorkspaceForFocusedApp(force: Bool = false) {
        DispatchQueue.main.async {
            guard let activeApp = NSWorkspace.shared.frontmostApplication else { return }
            guard !activeApp.isFinderDesktopInteraction else { return }

            self.activeApplicationChanged(activeApp, force: force)
        }
    }

    private func activeApplicationChanged(_ app: NSRunningApplication, force: Bool) {
        let workspaceSettings = settingsRepository.workspaceSettings
        let pipSettings = settingsRepository.pictureInPictureSettings

        guard force || workspaceSettings.activeWorkspaceOnFocusChange else { return }

        let activeWorkspaces = workspaceManager.activeWorkspace.values

        // Skip if the workspace was activated recently
        guard Date().timeIntervalSince(workspaceManager.lastWorkspaceActivation) > 0.2 else { return }

        // Skip if the app is floating
        guard !settingsRepository.floatingAppsSettings.floatingApps.containsApp(app) else { return }

        // Finder is managed per-window by FinderWindowManager, not as a whole app
        guard !app.isFinder else { return }

        workspaceManager.invalidateInactiveWorkspaces()

        // Find the workspace that contains the app.
        // Temp assignments take priority (they suppress permanent assignments
        // when an app has been deliberately moved via minimize/drag).
        // Among permanent assignments, active workspaces are checked first.
        let workspace: Workspace? =
            workspaceRepository.workspaces.first(where: {
                workspaceManager.isTemporaryApp(app.toMacApp, in: $0.id)
            }) ??
            (activeWorkspaces + workspaceRepository.workspaces).first(where: {
                $0.apps.containsApp(app)
            })
        guard let workspace else { return }

        // In isolation mode, don't switch if the workspace is on a different
        // display than where the app currently is.
        if workspaceSettings.isolateSecondaryDisplays,
           NSScreen.screens.count > 1,
           let appDisplay = app.display {
            let wsDisplay = AppDependencies.shared.displayManager.resolveDisplay(workspace.display)
            if appDisplay != wsDisplay {
                return
            }
        }

        // Skip if the workspace is already active
        guard activeWorkspaces.count(where: { $0.id == workspace.id }) < workspace.displays.count else { return }

        // Skip if the focused window is in Picture in Picture mode
        guard !pipSettings.enablePictureInPictureSupport ||
            !app.supportsPictureInPicture ||
            app.focusedWindow?.isPictureInPicture(bundleId: app.bundleIdentifier) != true else { return }

        let activate = { [self] in
            Logger.log("")
            Logger.log("")
            Logger.log("Activating workspace for app: \(workspace.name)")
            workspaceManager.updateLastFocusedApp(app.toMacApp, in: workspace)
            workspaceManager.activateWorkspace(workspace, setFocus: false)
            app.activate()

            // Restore the app if it was hidden
            if pipSettings.enablePictureInPictureSupport, app.supportsPictureInPicture {
                pictureInPictureManager.restoreAppIfNeeded(app: app)
            }
        }

        if workspace.isDynamic, workspace.displays.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
                activate()
            }
        } else {
            activate()
        }
    }

    private func clearFinderFocusForActiveWorkspace() {
        let display = DisplayName.current
        let activeWorkspaces = workspaceManager.activeWorkspace.values
        guard let activeWorkspace = activeWorkspaces.first(where: { $0.displays.contains(display) })
            ?? activeWorkspaces.first else { return }

        AppDependencies.shared.finderWindowManager.clearFinderFocus(for: activeWorkspace.id)
    }

    /// Opening a folder that is already open in a Finder window hidden on another
    /// workspace focuses that off-screen window. Switch to its workspace to show it.
    private func finderFocusedWindowChanged() {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) else { return }

        let previousWindow = lastFocusedFinderWindow
        let focusedWindow = finder.focusedWindow?.cgWindowId
        lastFocusedFinderWindow = focusedWindow

        let finderWindowManager = AppDependencies.shared.finderWindowManager

        guard let focusedWindow,
              NSWorkspace.shared.frontmostApplication == finder,
              // Skip focus changes caused by a workspace switch (raising restored windows)
              Date().timeIntervalSince(workspaceManager.lastWorkspaceActivation) > 0.4,
              let workspaceId = finderWindowManager.workspaceOfHiddenWindow(focusedWindow),
              let workspace = workspaceRepository.findWorkspace(with: workspaceId)
        else { return }

        // Closing or minimizing the focused window makes Finder focus the next one,
        // which may be hidden. That isn't a request to show it.
        if let previousWindow,
           !finder.allWindowElements.contains(where: { $0.cgWindowId == previousWindow && !$0.isMinimized }) {
            return
        }

        Logger.log("Hidden Finder window (id: \(focusedWindow)) was focused - switching to: \(workspace.name)")
        finderWindowManager.focusOnActivation(focusedWindow, in: workspace.id)
        workspaceManager.activateWorkspace(workspace, setFocus: false)
    }

    private func handleFinderWindowFocus(_ app: NSRunningApplication) {
        // Track which workspace this Finder window belongs to
        let display = DisplayName.current
        let activeWorkspaces = workspaceManager.activeWorkspace.values
        guard let activeWorkspace = activeWorkspaces.first(where: { $0.displays.contains(display) })
            ?? activeWorkspaces.first else { return }

        let finderWindowManager = AppDependencies.shared.finderWindowManager
        finderWindowManager.trackFocusedFinderWindow(in: activeWorkspace.id)
    }

    private func temporarilyAssignAppIfNeeded(_ app: NSRunningApplication) {
        guard settingsRepository.workspaceSettings.enableTemporaryAppAssignment else { return }

        // Finder is managed per-window by FinderWindowManager, not as a whole app
        guard !app.isFinder else { return }

        // Skip if the app is floating
        guard !settingsRepository.floatingAppsSettings.floatingApps.containsApp(app) else { return }

        // Find the active workspace on the current display
        let display = DisplayName.current
        let activeWorkspaces = workspaceManager.activeWorkspace.values
        let activeWorkspace = activeWorkspaces.first { $0.displays.contains(display) }
            ?? activeWorkspaces.first

        guard let activeWorkspace else { return }

        let isPermanentlyAssigned = workspaceRepository.workspaces.contains { $0.apps.containsApp(app) }
        let isTempAssigned = workspaceManager.hasTemporaryAssignment(for: app.toMacApp)
        let isAssigned = isPermanentlyAssigned || isTempAssigned

        // Unassigned apps: temp assign to the current workspace (existing behavior)
        guard isAssigned else {
            workspaceManager.temporarilyAssignApp(app.toMacApp, to: activeWorkspace)
            return
        }

        // Find the app's "home" workspace (temp takes priority over perm)
        let homeWorkspace: Workspace? =
            workspaceRepository.workspaces.first(where: {
                workspaceManager.isTemporaryApp(app.toMacApp, in: $0.id)
            }) ??
            workspaceRepository.workspaces.first(where: { $0.apps.containsApp(app) })

        // Already on the home workspace → clean up any stale borrow state
        if homeWorkspace?.id == activeWorkspace.id {
            workspaceManager.removeBorrowedApp(app.toMacApp)
            return
        }

        // In isolation mode, if the app is on a different display than its
        // home workspace, reassign it to the workspace active on the app's
        // current display. This prevents cross-display workspace switches.
        if settingsRepository.workspaceSettings.isolateSecondaryDisplays,
           NSScreen.screens.count > 1,
           let appDisplay = app.display,
           let homeWs = homeWorkspace {
            let homeDisplay = AppDependencies.shared.displayManager.resolveDisplay(homeWs.display)
            if appDisplay != homeDisplay,
               let targetWorkspace = workspaceManager.activeWorkspace[appDisplay] {
                workspaceManager.removeBorrowedApp(app.toMacApp)
                workspaceManager.temporarilyAssignApp(app.toMacApp, to: targetWorkspace)
                Logger.log("Cross-display reassign: \(app.localizedName ?? "") → \(targetWorkspace.name)")
                return
            }
        }

        // App is assigned to a different workspace. Never move its assignment
        // implicitly — only the "Assign App" hotkey should do that.

        // Switch workspace on app focus ON → let activeApplicationChanged
        // switch to the app's home workspace.
        if settingsRepository.workspaceSettings.activeWorkspaceOnFocusChange {
            return
        }

        // Switch workspace on app focus OFF → borrow the app (visible on this
        // workspace until the user returns to the app's home workspace).
        workspaceManager.borrowApp(app.toMacApp, to: activeWorkspace)
    }

    private func autoAssignAppToWorkspaceIfNeeded(_ app: NSRunningApplication) {
        guard settingsRepository.workspaceSettings.autoAssignAppsToWorkspaces else { return }

        // Finder is managed per-window by FinderWindowManager
        guard !app.isFinder else { return }

        // Skip if the app is floating
        guard !settingsRepository.floatingAppsSettings.floatingApps.containsApp(app) else { return }

        // Skip if the app already has a temp assignment (runtime position)
        guard !workspaceManager.hasTemporaryAssignment(for: app.toMacApp) else { return }

        let workspaceWithApp = workspaceRepository.workspaces.first { $0.apps.containsApp(app) }

        // Skip if the app is already assigned to a workspace (default position)
        guard settingsRepository.workspaceSettings.autoAssignAlreadyAssignedApps ||
            workspaceWithApp == nil else { return }

        // Assign the app to the active workspace on the same display, or to the first active workspace if there is no active
        // workspace on the same display
        let display = DisplayName.current
        let activeWorkspaces = workspaceManager.activeWorkspace.values
        var activeWorkspace = activeWorkspaces.first { $0.displays.contains(display) }
            ?? activeWorkspaces.first

        if settingsRepository.workspaceSettings.displayMode == .dynamic,
           workspaceManager.activeWorkspace.isEmpty,
           activeWorkspace == nil {
            activeWorkspace = workspaceRepository.workspaces.first
        }

        if let activeWorkspace, activeWorkspace.id != workspaceWithApp?.id {
            workspaceManager.temporarilyAssignApp(app.toMacApp, to: activeWorkspace)
        }
    }
}
