//
//  AppDelegate.swift
//
//  Created by Wojciech Kulik on 13/02/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("firstLaunch") private var firstLaunch = true

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessibility calls to an unresponsive app block until they time out
        // (6s by default), freezing workspace switching. Set on the system-wide
        // element, the timeout applies to all Accessibility calls.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 3.0)

        AppDependencies.shared.hotKeysManager.enableAll()

        NotificationCenter.default
            .publisher(for: .openMainWindow)
            .sink { [weak self] _ in
                self?.openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .store(in: &cancellables)

        if firstLaunch {
            firstLaunch = false
        } else {
            dismissWindow(id: "main")

            if WhatsNewManager.shared.shouldShowWhatsNew {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.openWindow(id: "whats-new")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDependencies.shared.pictureInPictureManager.restoreAllWindows()
        AppDependencies.shared.finderWindowManager.restoreAllWindows()
    }
}
