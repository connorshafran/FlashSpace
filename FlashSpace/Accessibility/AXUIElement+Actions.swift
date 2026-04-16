//
//  AXUIElement+Actions.swift
//
//  Created by Wojciech Kulik on 16/02/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit

extension AXUIElement {
    /// Position is in window coordinates where (0,0) is top-left corner
    /// and it is relative to the main screen.
    func setPosition(_ position: CGPoint) {
        var position = position
        let positionRef = AXValueCreate(.cgPoint, &position)
        setAttribute(.position, value: positionRef)
    }

    func setSize(_ size: CGSize) {
        var size = size
        let sizeRef = AXValueCreate(.cgSize, &size)
        setAttribute(.size, value: sizeRef)
    }

    func focus() {
        AXUIElementPerformAction(self, NSAccessibility.Action.raise as CFString)
    }

    func minimize(_ minimized: Bool) {
        setAttribute(.minimized, value: minimized)
    }
}
