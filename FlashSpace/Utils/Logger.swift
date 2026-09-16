//
//  Logger.swift
//
//  Created by Wojciech Kulik on 16/02/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import Foundation

enum Logger {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// The message is only evaluated in debug builds, so interpolated values
    /// (which often query the Accessibility API) cost nothing in release builds.
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let dateString = dateFormatter.string(from: Date())
        print("\(dateString): \(message())")
        #endif
    }

    static func log(_ error: Error) {
        log("\(error)")
    }
}
