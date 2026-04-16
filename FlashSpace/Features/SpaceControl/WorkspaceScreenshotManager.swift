//
//  WorkspaceScreenshotManager.swift
//
//  Created by Wojciech Kulik on 11/02/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit
import Combine
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

final class WorkspaceScreenshotManager {
    typealias ImageData = Data

    struct ScreenshotKey: Hashable {
        let displayName: DisplayName
        let workspaceID: WorkspaceID
    }

    private(set) var screenshots: [ScreenshotKey: ImageData] = [:]
    private var cancellables = Set<AnyCancellable>()

    private let spaceControlSettings: SpaceControlSettings
    private let workspaceManager: WorkspaceManager
    private let lock = NSLock()

    init(
        spaceControlSettings: SpaceControlSettings,
        workspaceManager: WorkspaceManager
    ) {
        self.spaceControlSettings = spaceControlSettings
        self.workspaceManager = workspaceManager

        observe()
    }

    /// Fast capture of the current workspace for Space Control "Update on Open".
    /// Must be called from the main thread.
    func captureCurrentWorkspace() {
        guard PermissionsManager.shared.checkForScreenRecordingPermissions() else { return }

        let display = DisplayName.current
        guard let workspace = workspaceManager.activeWorkspace[display] else { return }

        captureDisplay(display, forWorkspace: workspace.id, inBackground: false)
    }

    /// Fast capture of a display using CGWindowListCreateImage.
    /// The CGImage is captured synchronously (must happen before the screen changes),
    /// then JPEG encoding + storage happens in the background if `inBackground` is true.
    /// Must be called from the main thread.
    func captureDisplay(_ displayName: DisplayName, forWorkspace workspaceId: WorkspaceID, inBackground: Bool = true) {
        guard !SpaceControl.isVisible,
              SpaceControl.isEnabled || WorkspaceSwitcher.isEnabled,
              PermissionsManager.shared.checkForScreenRecordingPermissions() else { return }

        guard let screen = NSScreen.screens.first(where: { $0.localizedName == displayName }) else { return }

        // Capture at 1x resolution (not retina 2x) -- plenty for thumbnails.
        // CGWindowListCreateImage is synchronous and fast (~5ms).
        guard let cgImage = CGWindowListCreateImage(
            screen.frame,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .nominalResolution
        ) else { return }

        let key = ScreenshotKey(displayName: displayName, workspaceID: workspaceId)

        if inBackground {
            // JPEG encode on a background queue -- doesn't block the workspace switch
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let jpegData = Self.encodeJPEG(cgImage) else { return }
                self?.lock.lock()
                self?.screenshots[key] = jpegData
                self?.lock.unlock()
            }
        } else {
            // Encode synchronously -- used when Space Control needs the image immediately
            guard let jpegData = Self.encodeJPEG(cgImage) else { return }
            lock.lock()
            screenshots[key] = jpegData
            lock.unlock()
        }
    }

    private static func encodeJPEG(_ cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.7
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return data as Data
    }

    func captureWorkspace(_ workspace: Workspace, displayName: DisplayName) async {
        let shouldCapture = await MainActor.run {
            !SpaceControl.isVisible &&
                (SpaceControl.isEnabled || WorkspaceSwitcher.isEnabled) &&
                PermissionsManager.shared.checkForScreenRecordingPermissions()
        }

        guard shouldCapture else { return }

        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let display = await MainActor.run {
                availableContent.displays.first { $0.frame.getDisplay() == displayName }
            }

            guard let display else { return }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.captureResolution = .best
            config.width = Int(display.frame.width)
            config.height = Int(display.frame.height)
            config.showsCursor = false

            let screenshot = try await SCScreenshotManager.captureSampleBuffer(
                contentFilter: filter,
                configuration: config
            )

            if let image = imageFromSampleBuffer(screenshot) {
                let key = ScreenshotKey(
                    displayName: displayName,
                    workspaceID: workspace.id
                )
                saveScreenshot(image, workspace: workspace, key: key)
            }
        } catch {
            Logger.log(error)
        }
    }

    private func imageFromSampleBuffer(_ buffer: CMSampleBuffer) -> NSImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }

        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let representation = NSCIImageRep(ciImage: ciImage)
        let nsImage = NSImage(size: representation.size)
        nsImage.addRepresentation(representation)

        return nsImage
    }

    private func saveScreenshot(_ image: NSImage, workspace: Workspace, key: ScreenshotKey) {
        let newWidth: CGFloat = 1900.0
        let newHeight = (newWidth / image.size.width) * image.size.height
        let newSize = CGSize(width: newWidth, height: newHeight)

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(newWidth),
            pixelsHigh: Int(newHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [:]) else { return }

        lock.lock()
        screenshots[key] = jpegData
        lock.unlock()
    }

    private func observe() {
        NotificationCenter.default
            .publisher(for: .profileChanged)
            .sink { [weak self] _ in
                self?.screenshots = [:]
            }
            .store(in: &cancellables)
    }
}
