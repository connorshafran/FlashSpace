//
//  WorkspaceManager.swift
//
//  Created by Wojciech Kulik on 19/01/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//
// swiftlint:disable file_length

import AppKit
import Combine

typealias DisplayName = String

struct ActiveWorkspace {
    let id: WorkspaceID
    let name: String
    let number: String?
    let symbolIconName: String?
    let display: DisplayName
}

// swiftlint:disable:next type_body_length
final class WorkspaceManager: ObservableObject {
    @Published private(set) var activeWorkspaceDetails: ActiveWorkspace?

    private(set) var lastFocusedApp: [ProfileId: [WorkspaceID: MacApp]] = [:]
    private(set) var activeWorkspace: [DisplayName: Workspace] = [:]
    private(set) var mostRecentWorkspace: [DisplayName: Workspace] = [:]
    private(set) var lastWorkspaceActivation = Date.distantPast
    private(set) var workspaceActivationTimes: [WorkspaceID: Date] = [:]
    private(set) var temporaryApps: [WorkspaceID: [MacApp]] = [:]

    /// Apps "borrowed" from their assigned workspace to be visible on another.
    /// Unlike temp assignments, borrows are automatically cleaned up when the
    /// user returns to the app's assigned workspace (permanent or temporary).
    private(set) var borrowedApps: [WorkspaceID: [MacApp]] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var observeFocusCancellable: AnyCancellable?
    private var appsHiddenManually: [WorkspaceID: [MacApp]] = [:]
    private let hideAgainSubject = PassthroughSubject<(Workspace, Set<DisplayName>), Never>()

    private lazy var focusedWindowTracker = AppDependencies.shared.focusedWindowTracker
    private lazy var finderWindowManager = AppDependencies.shared.finderWindowManager
    private lazy var workspaceScreenshotManager = AppDependencies.shared.workspaceScreenshotManager

    private let workspaceRepository: WorkspaceRepository
    private let workspaceSettings: WorkspaceSettings
    private let profilesRepository: ProfilesRepository
    private let floatingAppsSettings: FloatingAppsSettings
    private let pictureInPictureManager: PictureInPictureManager
    private let workspaceTransitionManager: WorkspaceTransitionManager
    private let displayManager: DisplayManager

    init(
        workspaceRepository: WorkspaceRepository,
        settingsRepository: SettingsRepository,
        profilesRepository: ProfilesRepository,
        pictureInPictureManager: PictureInPictureManager,
        workspaceTransitionManager: WorkspaceTransitionManager,
        displayManager: DisplayManager
    ) {
        self.workspaceRepository = workspaceRepository
        self.profilesRepository = profilesRepository
        self.workspaceSettings = settingsRepository.workspaceSettings
        self.floatingAppsSettings = settingsRepository.floatingAppsSettings
        self.pictureInPictureManager = pictureInPictureManager
        self.workspaceTransitionManager = workspaceTransitionManager
        self.displayManager = displayManager

        PermissionsManager.shared.askForAccessibilityPermissions()
        observe()
    }

    private func observe() {
        hideAgainSubject
            .debounce(for: 0.2, scheduler: RunLoop.main)
            .sink { [weak self] workspace, displays in self?.hideApps(in: workspace, on: displays) }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .profileChanged)
            .sink { [weak self] _ in
                self?.activeWorkspace = [:]
                self?.mostRecentWorkspace = [:]
                self?.activeWorkspaceDetails = nil
                self?.temporaryApps = [:]
                self?.borrowedApps = [:]
                self?.finderWindowManager.reset()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                self?.removeTerminatedTemporaryApp(app)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.activeWorkspace = [:]
                self?.mostRecentWorkspace = [:]
                self?.activeWorkspaceDetails = nil
            }
            .store(in: &cancellables)

        workspaceRepository.workspacesPublisher
            .sink { [weak self] workspaces in
                self?.updateWorkspaces(workspaces)
            }
            .store(in: &cancellables)

        workspaceSettings.$enableTemporaryAppAssignment
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.temporaryApps = [:]
                self?.borrowedApps = [:]
                NotificationCenter.default.post(name: .temporaryAppsChanged, object: nil)
            }
            .store(in: &cancellables)

        observeFocus()
    }

    private func observeFocus() {
        observeFocusCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.activationPolicy == .regular }
            .filter { !$0.isFinderDesktopInteraction }
            .sink { [weak self] application in
                self?.invalidateInactiveWorkspaces()
                self?.rememberLastFocusedApp(application, retry: true)
            }
    }

    private func rememberLastFocusedApp(_ application: NSRunningApplication, retry: Bool) {
        guard application.display != nil else {
            if retry {
                Logger.log("Retrying to get display for \(application.localizedName ?? "")")
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let frontmostApp = NSWorkspace.shared.frontmostApplication {
                        self.rememberLastFocusedApp(frontmostApp, retry: false)
                    }
                }
            } else {
                return Logger.log("Unable to get display for \(application.localizedName ?? "")")
            }
        }

        let focusedDisplay = DisplayName.current

        if let activeWorkspace = activeWorkspace[focusedDisplay],
           activeWorkspace.apps.containsApp(application) ||
           (temporaryApps[activeWorkspace.id] ?? []).containsApp(application) ||
           (borrowedApps[activeWorkspace.id] ?? []).containsApp(application) {
            updateLastFocusedApp(application.toMacApp, in: activeWorkspace)
            updateActiveWorkspace(activeWorkspace, on: [focusedDisplay])
        }

        displayManager.trackDisplayFocus(on: focusedDisplay, for: application)
    }

    private func updateWorkspaces(_ workspaces: [Workspace]) {
        let updatedWorkspaces = workspaces.reduce(into: [WorkspaceID: Workspace]()) { $0[$1.id] = $1 }

        // Restore any Finder windows belonging to deleted workspaces
        finderWindowManager.restoreWindowsNotIn(validWorkspaces: Set(updatedWorkspaces.keys))

        for (display, workspace) in activeWorkspace {
            activeWorkspace[display] = updatedWorkspaces[workspace.id]
        }

        for (display, workspace) in mostRecentWorkspace {
            mostRecentWorkspace[display] = updatedWorkspaces[workspace.id]
        }
    }

    private func showApps(in workspace: Workspace, setFocus: Bool, on displays: Set<DisplayName>) {
        let regularApps = NSWorkspace.shared.runningRegularApps
        let floatingApps = floatingAppsSettings.floatingApps
        let hiddenApps = appsHiddenManually[workspace.id] ?? []
        let tempApps = temporaryApps[workspace.id] ?? []
        let borrowed = borrowedApps[workspace.id] ?? []

        // Apps that have been moved (temp assignment) or borrowed to another
        // workspace should be suppressed on their original workspace.
        let movedAway = temporaryApps.filter { $0.key != workspace.id }
            .values.flatMap { $0 }.map(\.bundleIdentifier)
        let borrowedAway = borrowedApps.filter { $0.key != workspace.id }
            .values.flatMap { $0 }.map(\.bundleIdentifier)
        let suppressedBundleIds = Set(movedAway + borrowedAway)

        var appsToShow = regularApps
            .filter { !$0.isFinder } // Finder windows managed individually by FinderWindowManager
            .filter { !hiddenApps.containsApp($0) }
            .filter { !suppressedBundleIds.contains($0.bundleIdentifier ?? "") }
            .filter {
                workspace.apps.containsApp($0) ||
                    tempApps.containsApp($0) ||
                    borrowed.containsApp($0) ||
                    floatingApps.containsApp($0) && $0.isOnAnyDisplay(displays)
            }

        // In isolation mode, don't raise apps that are visible on other displays
        if workspaceSettings.isolateSecondaryDisplays, NSScreen.screens.count > 1 {
            appsToShow = appsToShow.filter {
                $0.isHidden || $0.isMinimized || $0.isOnAnyDisplay(displays)
            }
        }

        observeFocusCancellable = nil
        defer { observeFocus() }

        if setFocus {
            let toFocus = findAppToFocus(in: workspace, apps: appsToShow)

            // Make sure to raise the app that should be focused
            // as the last one
            if let toFocus {
                appsToShow.removeAll { $0 == toFocus }
                appsToShow.append(toFocus)
            }

            for app in appsToShow {
                Logger.log("SHOW: \(app.localizedName ?? "")")

                if app == toFocus || app.isHidden || app.isMinimized {
                    app.raise()
                }

                pictureInPictureManager.showPipAppIfNeeded(app: app)
                pictureInPictureManager.showCornerHiddenAppIfNeeded(app: app)
            }

            Logger.log("FOCUS: \(toFocus?.localizedName ?? "")")
            toFocus?.activate()
            centerCursorIfNeeded(in: toFocus?.frame)
        } else {
            for app in appsToShow {
                Logger.log("SHOW: \(app.localizedName ?? "")")
                app.raise()
            }
        }
    }

    private func hideApps(in workspace: Workspace, on displays: Set<DisplayName>) {
        let regularApps = NSWorkspace.shared.runningRegularApps
        let tempApps = temporaryApps[workspace.id] ?? []
        let borrowed = borrowedApps[workspace.id] ?? []

        // Apps that have been moved (temp assignment) or borrowed to another
        // workspace should not count as "belonging" to this workspace for hiding,
        // even if they have a default assignment here.
        let movedAway = temporaryApps.filter { $0.key != workspace.id }
            .values.flatMap { $0 }.map(\.bundleIdentifier).asSet
        let borrowedAway = borrowedApps.filter { $0.key != workspace.id }
            .values.flatMap { $0 }.map(\.bundleIdentifier).asSet
        let suppressedBundleIds = movedAway.union(borrowedAway)

        let workspaceApps = (workspace.apps + tempApps + borrowed + floatingAppsSettings.floatingApps)
            .filter { !suppressedBundleIds.contains($0.bundleIdentifier) }
        let isAnyWorkspaceAppRunning = regularApps
            .contains { workspaceApps.containsApp($0) }
        let allTempApps = temporaryApps.values.flatMap { $0 }.map(\.bundleIdentifier)
        let allBorrowedApps = borrowedApps.values.flatMap { $0 }.map(\.bundleIdentifier)
        let allAssignedApps = (workspaceRepository.workspaces
            .flatMap(\.apps)
            .map(\.bundleIdentifier) + allTempApps + allBorrowedApps)
            .asSet

        let appsToHide = regularApps
            .filter { !$0.isFinder } // Finder windows managed individually by FinderWindowManager
            .filter {
                !$0.isHidden && !workspaceApps.containsApp($0) &&
                    (!workspaceSettings.keepUnassignedAppsOnSwitch || allAssignedApps.contains($0.bundleIdentifier ?? ""))
            }
            .filter { isAnyWorkspaceAppRunning || $0.bundleURL?.fileName != "Finder" }
            .filter { $0.isOnAnyDisplay(displays) }

        for app in appsToHide {
            Logger.log("HIDE: \(app.localizedName ?? "")")

            if !pictureInPictureManager.hideCornerHiddenAppIfNeeded(app: app),
               !pictureInPictureManager.hidePipAppIfNeeded(app: app) {
                app.hide()
            }
        }
    }

    private func findAppToFocus(
        in workspace: Workspace,
        apps: [NSRunningApplication]
    ) -> NSRunningApplication? {
        if workspace.appToFocus == nil {
            let displays = workspace.displays
            if let floatingEntry = displayManager.lastFocusedDisplay(where: {
                let isFloating = floatingAppsSettings.floatingApps.contains($0.app)
                let isUnassigned = workspaceSettings.keepUnassignedAppsOnSwitch &&
                    !workspaceRepository.workspaces.flatMap(\.apps).contains($0.app)
                return (isFloating || isUnassigned) && displays.contains($0.display)
            }),
                let runningApp = NSWorkspace.shared.runningApplications.find(floatingEntry.app) {
                return runningApp
            }
        }

        var appToFocus: NSRunningApplication?

        if workspace.appToFocus == nil {
            appToFocus = apps.find(lastFocusedApp[profilesRepository.selectedProfile.id, default: [:]][workspace.id])
        } else {
            appToFocus = apps.find(workspace.appToFocus)
        }

        let tempApps = temporaryApps[workspace.id] ?? []
        let borrowed = borrowedApps[workspace.id] ?? []
        let allWorkspaceApps = workspace.apps + tempApps + borrowed
        let fallbackToLastApp = apps.findFirstMatch(with: allWorkspaceApps.reversed())
        let fallbackToFinder = NSWorkspace.shared.runningApplications.first(where: \.isFinder)

        return appToFocus ?? fallbackToLastApp ?? fallbackToFinder
    }

    private func centerCursorIfNeeded(in frame: CGRect?) {
        guard workspaceSettings.centerCursorOnWorkspaceChange, let frame else { return }

        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func updateActiveWorkspace(_ workspace: Workspace, on displays: Set<DisplayName>) {
        lastWorkspaceActivation = Date()

        // Save the most recent workspace if it's not the current one
        for display in displays {
            if activeWorkspace[display]?.id != workspace.id {
                mostRecentWorkspace[display] = activeWorkspace[display]
            }
            activeWorkspace[display] = workspace
        }

        activeWorkspaceDetails = .init(
            id: workspace.id,
            name: workspace.name,
            number: workspaceRepository.workspaces
                .firstIndex { $0.id == workspace.id }
                .map { "\($0 + 1)" },
            symbolIconName: workspace.symbolIconName,
            display: workspace.displayForPrint
        )

        Integrations.runOnActivateIfNeeded(workspace: activeWorkspaceDetails!)
    }

    private func updateLastActivationTime(for workspace: Workspace) {
        workspaceActivationTimes[workspace.id] = Date()
    }

    private func openAppsIfNeeded(in workspace: Workspace) {
        guard workspace.openAppsOnActivation == true else { return }

        let runningBundleIds = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .asSet

        workspace.apps
            .filter {
                !runningBundleIds.contains($0.bundleIdentifier) &&
                    $0.autoOpen == true
            }
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) }
            .forEach { appUrl in
                Logger.log("Open App: \(appUrl)")

                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: appUrl, configuration: config) { _, error in
                    if let error {
                        Logger.log("Failed to open \(appUrl): \(error.localizedDescription)")
                    }
                }
            }
    }

    private func rememberHiddenApps(workspaceToActivate: WorkspaceID?) {
        guard !workspaceSettings.restoreHiddenAppsOnSwitch else {
            appsHiddenManually = [:]
            return
        }

        let hiddenApps = NSWorkspace.shared.runningRegularApps
            .filter { $0.isHidden || $0.isMinimized }

        for activeWorkspace in activeWorkspace.values {
            guard activeWorkspace.id != workspaceToActivate else { continue }

            appsHiddenManually[activeWorkspace.id] = []
        }

        for (display, activeWorkspace) in activeWorkspace {
            guard activeWorkspace.id != workspaceToActivate else { continue }

            let activeWorkspaceOtherDisplays = activeWorkspace.displays.subtracting([display])
            appsHiddenManually[activeWorkspace.id, default: []] += hiddenApps
                .filter {
                    activeWorkspace.apps.containsApp($0) &&
                        $0.isOnAnyDisplay([display]) && !$0.isOnAnyDisplay(activeWorkspaceOtherDisplays)
                }
                .map(\.toMacApp)
        }
    }

    private func deactivateActiveWorkspace(on display: DisplayName) {
        workspaceTransitionManager.showTransitionIfNeeded(for: nil, on: [display])
        rememberHiddenApps(workspaceToActivate: nil)

        if let activeWorkspace = activeWorkspace[display] {
            mostRecentWorkspace[display] = activeWorkspace
        }

        lastWorkspaceActivation = Date()
        activeWorkspaceDetails = nil
        activeWorkspace.removeValue(forKey: display)
    }
}

// MARK: - Workspace Actions
extension WorkspaceManager {
    func activateWorkspace(_ workspace: Workspace, setFocus: Bool) {
        guard !workspaceSettings.isPaused else {
            Logger.log("Workspace management is paused - skipping activation")
            return
        }

        var displays = workspace.displays
        let isolating = workspaceSettings.isolateSecondaryDisplays && NSScreen.screens.count > 1

        // When isolating secondary displays, restrict operations to the workspace's
        // assigned display only. Apps on other displays remain untouched.
        if isolating {
            displays = [displayManager.resolveDisplay(workspace.display)]
        }

        Logger.log("")
        Logger.log("")
        Logger.log("WORKSPACE: \(workspace.name)")
        Logger.log("DISPLAYS: \(displays.joined(separator: ", "))")
        if isolating { Logger.log("ISOLATING: secondary displays excluded") }
        Logger.log("----")
        let wasSpaceControlVisible = SpaceControl.isVisible
        SpaceControl.hide()

        if workspace.isDynamic, workspace.displays.isEmpty,
           workspace.apps.isNotEmpty, workspace.openAppsOnActivation == true {
            Logger.log("No running apps in the workspace - launching apps")
            openAppsIfNeeded(in: workspace)

            if !workspaceSettings.activeWorkspaceOnFocusChange {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.activateWorkspace(workspace, setFocus: setFocus)
                }
            }
            return
        }

        guard displays.isNotEmpty else {
            Logger.log("No displays found for workspace: \(workspace.name) - skipping")
            return
        }

        focusedWindowTracker.stopTracking()
        defer { focusedWindowTracker.startTracking() }

        // Capture the workspace being LEFT before the screen changes.
        // The CGImage is grabbed synchronously (~5ms), JPEG encoding happens in the background.
        let onDisplays: Set<DisplayName>? = isolating ? displays : nil
        if let currentDisplay = displays.first,
           let currentWorkspace = activeWorkspace[currentDisplay] {
            // Track all visible Finder windows to the workspace being LEFT.
            finderWindowManager.trackAllVisibleFinderWindows(in: currentWorkspace.id, onDisplays: onDisplays)

            // Snapshot the departing workspace for Space Control / Workspace Switcher.
            // Skip if Space Control was just showing — the overlay may still be compositing,
            // and the workspace was already captured when Space Control opened.
            if !wasSpaceControlVisible {
                workspaceScreenshotManager.captureDisplay(currentDisplay, forWorkspace: currentWorkspace.id)
            }
        }

        workspaceTransitionManager.showTransitionIfNeeded(for: workspace, on: displays)

        // Pull back borrowed apps that belong to this workspace's assignments.
        cleanUpBorrowsOnReturn(to: workspace)

        rememberHiddenApps(workspaceToActivate: workspace.id)
        updateLastActivationTime(for: workspace)
        updateActiveWorkspace(workspace, on: displays)
        openAppsIfNeeded(in: workspace)
        showApps(in: workspace, setFocus: setFocus, on: displays)
        hideApps(in: workspace, on: displays)
        finderWindowManager.activateWorkspace(workspace.id, onDisplays: onDisplays)
        runIntegrationAfterActivation(for: workspace)

        // Some apps may not hide properly,
        // so we hide apps in the workspace after a short delay
        hideAgainSubject.send((workspace, displays))

        // Measure the "recently activated" window from the end of the switch.
        // Showing and hiding apps can take longer than that window, and the
        // activation notifications it causes are only delivered afterwards.
        lastWorkspaceActivation = Date()
    }

    private func runIntegrationAfterActivation(for workspace: Workspace) {
        let newWorkspace = ActiveWorkspace(
            id: workspace.id,
            name: workspace.name,
            number: workspaceRepository.workspaces
                .firstIndex { $0.id == workspace.id }
                .map { "\($0 + 1)" },
            symbolIconName: workspace.symbolIconName,
            display: workspace.displayForPrint
        )

        Integrations.runAfterActivationIfNeeded(workspace: newWorkspace)
    }

    /// Moves an app to a target workspace at runtime via hotkey or CLI.
    /// Creates a temporary assignment (suppresses any default assignment).
    /// Always switches to the target workspace so the app stays visible.
    func moveAppToWorkspace(_ app: MacApp, to workspace: Workspace, switchToWorkspace: Bool = true) {
        removeBorrowedApp(app)
        temporarilyAssignApp(app, to: workspace)

        if switchToWorkspace {
            // Move the app's window off-screen before the workspace switch so
            // the source workspace's screenshot (captured at the start of
            // activateWorkspace) won't include the moved app. This is synchronous
            // unlike NSRunningApplication.hide() which is async.
            let runningApp = NSWorkspace.shared.runningApplications.find(app)
            var savedFrame: CGRect?

            if let runningApp, let frame = runningApp.frame {
                savedFrame = frame
                let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 2000
                runningApp.runWithoutAnimations {
                    runningApp.setPosition(CGPoint(x: maxX + 100, y: frame.origin.y))
                }
            }

            activateWorkspace(workspace, setFocus: true)

            // Restore the window position on the target workspace and
            // re-activate so it's on top of the z-order (showApps tried
            // to focus it while it was off-screen, which doesn't stick).
            if let runningApp, let savedFrame {
                runningApp.runWithoutAnimations {
                    runningApp.setPosition(savedFrame.origin)
                }
                runningApp.raise()
                runningApp.activate()
                lastWorkspaceActivation = Date()
            }
        }
    }

    func hideAll() {
        guard let display = DisplayName.currentOptional else { return }

        focusedWindowTracker.stopTracking()
        defer { focusedWindowTracker.startTracking() }

        deactivateActiveWorkspace(on: display)

        let appsToHide = NSWorkspace.shared.runningApplications
            .regularVisibleApps(onDisplays: [display], excluding: [])
            .filter { !$0.isFinder }

        for app in appsToHide {
            Logger.log("CLEAN UP: \(app.localizedName ?? "")")
            app.hide()
        }

        // Restore all Finder windows since no workspace is active
        finderWindowManager.restoreAllWindows()

        if let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) {
            finder.activate()
        }
    }

    func hideUnassignedApps() {
        guard let id = activeWorkspaceDetails?.id,
              let activeWorkspace = workspaceRepository.findWorkspace(with: id) else { return }

        let appsToHide = NSWorkspace.shared.runningApplications
            .regularVisibleApps(onDisplays: activeWorkspace.displays, excluding: activeWorkspace.apps)
            .filter { !$0.isFinder }

        for app in appsToHide {
            Logger.log("CLEAN UP: \(app.localizedName ?? "")")

            if !pictureInPictureManager.hidePipAppIfNeeded(app: app) {
                app.hide()
            }
        }
    }

    func showUnassignedApps() {
        guard let display = DisplayName.currentOptional else { return }

        Logger.log("")
        Logger.log("")
        Logger.log("SHOW UNASSIGNED APPS")

        let allWorkspacesApps = workspaceRepository.workspaces.flatMap(\.apps)
        let unassignedApps = NSWorkspace.shared.runningApplications
            .regularApps(onDisplays: [display], excluding: allWorkspacesApps)
        let appsToHide = NSWorkspace.shared.runningApplications
            .regularVisibleApps(onDisplays: [display], excluding: unassignedApps.map(\.toMacApp))

        focusedWindowTracker.stopTracking()
        defer { focusedWindowTracker.startTracking() }

        deactivateActiveWorkspace(on: display)

        for app in unassignedApps {
            Logger.log("SHOW UNASSIGNED: \(app.localizedName ?? "")")
            app.raise()
        }

        for app in appsToHide {
            if unassignedApps.isNotEmpty || !app.isFinder {
                Logger.log("HIDE ASSIGNED: \(app.localizedName ?? "")")

                if !pictureInPictureManager.hidePipAppIfNeeded(app: app) {
                    app.hide()
                }
            }
        }

        (unassignedApps.first ?? NSWorkspace.shared.runningApplications.first(where: \.isFinder))?
            .activate()
    }

    func activateWorkspace(next: Bool, skipEmpty: Bool, loop: Bool) {
        let screen = workspaceSettings.switchWorkspaceOnCursorScreen
            ? displayManager.getCursorScreen()
            : DisplayName.currentOptional

        guard let screen else { return }

        var workspacesToLoop = workspaceRepository.workspaces

        if !workspaceSettings.loopWorkspacesOnAllDisplays {
            workspacesToLoop = workspacesToLoop
                .filter { $0.displays.contains(screen) }
        }

        if !next {
            workspacesToLoop = workspacesToLoop.reversed()
        }

        guard let activeWorkspace = activeWorkspace[screen] ?? workspacesToLoop.first else { return }

        let nextWorkspaces = workspacesToLoop
            .drop(while: { $0.id != activeWorkspace.id })
            .dropFirst()

        var selectedWorkspace = nextWorkspaces.first ?? (loop ? workspacesToLoop.first : nil)

        if skipEmpty {
            let runningApps = NSWorkspace.shared.runningRegularApps
                .compactMap(\.bundleIdentifier)
                .asSet

            selectedWorkspace = (nextWorkspaces + (loop ? workspacesToLoop : []))
                .drop(while: { $0.apps.allSatisfy { !runningApps.contains($0.bundleIdentifier) } })
                .first
        }

        guard let selectedWorkspace, selectedWorkspace.id != activeWorkspace.id else { return }

        activateWorkspace(selectedWorkspace, setFocus: true)
    }

    func activateRecentWorkspace() {
        var screen = displayManager.getCursorScreen()

        // In isolation mode, always act on the primary display
        if workspaceSettings.isolateSecondaryDisplays, NSScreen.screens.count > 1 {
            screen = NSScreen.screens.first?.localizedName
        }

        guard let screen, let mostRecentWorkspace = mostRecentWorkspace[screen] else { return }

        activateWorkspace(mostRecentWorkspace, setFocus: true)
    }

    func activateWorkspaceIfActive(_ workspaceId: WorkspaceID) {
        guard activeWorkspace.values.contains(where: { $0.id == workspaceId }) else { return }
        guard let updatedWorkspace = workspaceRepository.findWorkspace(with: workspaceId) else { return }

        activateWorkspace(updatedWorkspace, setFocus: false)
    }

    func updateLastFocusedApp(_ app: MacApp, in workspace: Workspace) {
        lastFocusedApp[profilesRepository.selectedProfile.id, default: [:]][workspace.id] = app
    }

    func invalidateInactiveWorkspaces() {
        guard workspaceSettings.displayMode == .dynamic else { return }

        activeWorkspace = activeWorkspace.filter { display, workspace in
            let isValid = workspace.displays.contains(display)
            if !isValid {
                Logger.log("Invalidating workspace: \(workspace.name) on display: \(display)")
            }
            return isValid
        }
    }

    func pauseWorkspaceManagement() {
        guard !workspaceSettings.isPaused else { return }

        Logger.log("Pausing workspace management")
        workspaceSettings.isPaused = true
        focusedWindowTracker.stopTracking()
    }

    func resumeWorkspaceManagement() {
        guard workspaceSettings.isPaused else { return }

        Logger.log("Resuming workspace management")
        workspaceSettings.isPaused = false
        focusedWindowTracker.startTracking()
    }

    func togglePauseWorkspaceManagement() {
        if workspaceSettings.isPaused {
            resumeWorkspaceManagement()
        } else {
            pauseWorkspaceManagement()
        }
    }

    // MARK: - Temporary App Assignment

    func temporarilyAssignApp(_ app: MacApp, to workspace: Workspace) {
        // Remove from any other workspace's temporary list
        for (wsId, apps) in temporaryApps where wsId != workspace.id {
            if apps.contains(app) {
                temporaryApps[wsId] = apps.filter { $0 != app }
                if temporaryApps[wsId]?.isEmpty == true {
                    temporaryApps.removeValue(forKey: wsId)
                }
            }
        }

        // Add to the target workspace if not already there
        if !(temporaryApps[workspace.id] ?? []).contains(app) {
            temporaryApps[workspace.id, default: []].append(app)
            Logger.log("Temporarily assigned \(app.name) to workspace: \(workspace.name)")
        }

        // Record as last focused app so it gets focus when switching back to this workspace.
        // This must happen here because the observeFocus subscription may fire before the
        // temp assignment, causing rememberLastFocusedApp to miss the app.
        updateLastFocusedApp(app, in: workspace)

        NotificationCenter.default.post(name: .temporaryAppsChanged, object: nil)
    }

    func temporaryApps(for workspaceId: WorkspaceID) -> [MacApp] {
        temporaryApps[workspaceId] ?? []
    }

    func isTemporaryApp(_ app: MacApp, in workspaceId: WorkspaceID) -> Bool {
        temporaryApps[workspaceId]?.contains(app) ?? false
    }

    func removeTemporaryApp(_ app: MacApp, from workspaceId: WorkspaceID? = nil) {
        var changed = false
        let idsToCheck = workspaceId.map { [$0] } ?? Array(temporaryApps.keys)
        for wsId in idsToCheck {
            if let apps = temporaryApps[wsId], apps.contains(app) {
                temporaryApps[wsId] = apps.filter { $0 != app }
                if temporaryApps[wsId]?.isEmpty == true {
                    temporaryApps.removeValue(forKey: wsId)
                }
                changed = true
            }
        }
        if changed {
            NotificationCenter.default.post(name: .temporaryAppsChanged, object: nil)
        }
    }

    private func removeTerminatedTemporaryApp(_ app: NSRunningApplication) {
        let macApp = app.toMacApp
        var changed = false

        for (wsId, apps) in temporaryApps {
            if apps.contains(macApp) {
                temporaryApps[wsId] = apps.filter { $0 != macApp }
                if temporaryApps[wsId]?.isEmpty == true {
                    temporaryApps.removeValue(forKey: wsId)
                }
                changed = true
                Logger.log("Removed terminated temporary app: \(macApp.name)")
            }
        }

        // Also clean up borrowed state
        removeBorrowedApp(macApp)

        if changed {
            NotificationCenter.default.post(name: .temporaryAppsChanged, object: nil)
        }
    }

    // MARK: - Borrowed Apps

    /// Borrows a permanently-assigned app to a workspace, making it visible there
    /// without creating a temporary assignment.  The borrow is automatically
    /// cleaned up when the user returns to the app's permanent workspace.
    func borrowApp(_ app: MacApp, to workspace: Workspace) {
        // Remove from any other workspace's borrowed list
        for (wsId, apps) in borrowedApps where wsId != workspace.id {
            if apps.contains(app) {
                borrowedApps[wsId] = apps.filter { $0 != app }
                if borrowedApps[wsId]?.isEmpty == true {
                    borrowedApps.removeValue(forKey: wsId)
                }
            }
        }

        // Add to the target workspace if not already there
        if !(borrowedApps[workspace.id] ?? []).contains(app) {
            borrowedApps[workspace.id, default: []].append(app)
            Logger.log("Borrowed \(app.name) to workspace: \(workspace.name)")
        }

        updateLastFocusedApp(app, in: workspace)
    }

    func removeBorrowedApp(_ app: MacApp) {
        for (wsId, apps) in borrowedApps where apps.contains(app) {
            borrowedApps[wsId] = apps.filter { $0 != app }
            if borrowedApps[wsId]?.isEmpty == true {
                borrowedApps.removeValue(forKey: wsId)
            }
        }
    }

    func isBorrowedApp(_ app: MacApp, in workspaceId: WorkspaceID) -> Bool {
        borrowedApps[workspaceId]?.contains(app) ?? false
    }

    /// Returns true if the given app has a temporary assignment in any workspace.
    func hasTemporaryAssignment(for app: MacApp) -> Bool {
        temporaryApps.values.contains { $0.contains(app) }
    }

    /// Removes all borrows of apps that belong to the given workspace
    /// (both permanent and temporary assignments).
    /// Called when activating a workspace to "pull back" its apps.
    private func cleanUpBorrowsOnReturn(to workspace: Workspace) {
        let homeApps = workspace.apps + (temporaryApps[workspace.id] ?? [])
        for app in homeApps {
            var removed = false
            for (wsId, apps) in borrowedApps where wsId != workspace.id {
                if apps.contains(app) {
                    borrowedApps[wsId] = apps.filter { $0 != app }
                    if borrowedApps[wsId]?.isEmpty == true {
                        borrowedApps.removeValue(forKey: wsId)
                    }
                    removed = true
                }
            }
            if removed {
                Logger.log("Pulled back borrowed app \(app.name) to workspace: \(workspace.name)")
            }
        }
    }
}
