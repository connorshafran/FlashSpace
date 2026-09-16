//
//  System.swift
//
//  Created by Wojciech Kulik on 01/05/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit

struct AppWindow {
    let name: String
    let pid: pid_t
}

enum System {
    static var orderedWindows: [AppWindow] {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        guard let list else { return [] }

        return list.compactMap {
            let windowName = $0[kCGWindowName as String] as? String
            let windowOwnerPID = $0[kCGWindowOwnerPID as String] as? pid_t
            if let windowOwnerPID {
                return AppWindow(name: windowName ?? "-", pid: windowOwnerPID)
            } else {
                return nil
            }
        }
    }
}

enum WindowServer {
    private static var cachedFrames: [pid_t: [CGRect]] = [:]
    private static var cacheDate = Date.distantPast

    /// Frames of normal windows owned by the process, on all Spaces, including
    /// windows the Accessibility API can't see from the current Space.
    /// Frames are in the same top-left based coordinates as the Accessibility API.
    /// The window list is cached briefly because it's queried per app.
    static func windowFrames(for pid: pid_t) -> [CGRect] {
        if Date().timeIntervalSince(cacheDate) > 0.1 {
            cachedFrames = normalWindowFrames()
            cacheDate = Date()
        }

        return cachedFrames[pid] ?? []
    }

    private static func normalWindowFrames() -> [pid_t: [CGRect]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        return list.reduce(into: [:]) { result, window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 100, frame.height >= 100
            else { return }

            result[pid, default: []].append(frame)
        }
    }
}
