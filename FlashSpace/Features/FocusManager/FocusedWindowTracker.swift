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
                // Ignore Finder desktop interactions (clicking wallpaper, Show Desktop, etc.)
                guard !app.isFinderDesktopInteraction else { return }

                if app.isFinder {
                    self?.handleFinderWindowFocus(app)
                } else {
                    self?.clearFinderFocusForActiveWorkspace()
                    self?.temporarilyAssignAppIfNeeded(app)
                    self?.activeApplicationChanged(app, force: false)
                    self?.autoAssignAppToWorkspaceIfNeeded(app)
                }
            }
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
