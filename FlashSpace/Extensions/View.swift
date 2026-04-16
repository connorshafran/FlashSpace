//
//  View.swift
//
//  Created by Wojciech Kulik on 25/01/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import SwiftUI

extension View {
    func hotkey(_ title: String, name: HotKeyName, for hotKey: Binding<AppHotKey?>) -> some View {
        HStack {
            Text(title)
            Spacer()
            HotKeyControl(name: name, shortcut: hotKey).fixedSize()
        }
    }

    @ViewBuilder
    func hidden(_ isHidden: Bool) -> some View {
        if !isHidden {
            self
        }
    }

    @ViewBuilder
    func tahoeBorder() -> some View {
        if #available(macOS 26.0, *) {
            overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
        } else {
            self
        }
    }

    /// Conditionally applies a transform to the view.
    @ViewBuilder
    func ifTrue(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Adds a right-click handler that reports the click location in the window's coordinate space.
    func onRightClick(perform action: @escaping (CGPoint) -> ()) -> some View {
        overlay(
            RightClickOverlay(action: action)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}

/// NSView-based overlay that intercepts right-click events.
struct RightClickOverlay: NSViewRepresentable {
    let action: (CGPoint) -> ()

    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: RightClickNSView, context: Context) {
        nsView.action = action
    }
}

final class RightClickNSView: NSView {
    var action: ((CGPoint) -> ())?

    override func rightMouseDown(with event: NSEvent) {
        guard let windowContentView = window?.contentView else { return }

        // Convert to window content view coordinates (SwiftUI's coordinate space)
        let locationInWindow = event.locationInWindow
        let locationInContent = windowContentView.convert(locationInWindow, from: nil)

        // Flip Y (AppKit is bottom-up, SwiftUI is top-down)
        let flippedY = windowContentView.bounds.height - locationInContent.y
        action?(CGPoint(x: locationInContent.x, y: flippedY))
    }
}
