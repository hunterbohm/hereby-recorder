import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import Synchronization

/// One picture of the screen under the pointer, for a live question: the overlay and the recorder's own windows are
/// left out, and it is scaled so its long side is at most `maxSide` pixels and sent as base64 JPEG.
public enum ScreenGrab {
    public static let maxSide = 1280
    public static let quality = 0.6
    public static let timeout: Duration = .seconds(2)

    /// Nil when Screen Recording is off, the capture fails or takes longer than `timeout`. `ask` shows the system's
    /// Screen Recording prompt when it is off, for a question that needs the screen.
    public static func jpegBase64(ask: Bool) async -> String? {
        guard CGPreflightScreenCaptureAccess() else {
            if ask { _ = CGRequestScreenCaptureAccess() }
            return nil
        }
        // A task group would wait for a stalled capture, which can't be cancelled, so the first of the two answers
        // and the other is left to finish on its own.
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task { let image = try? await capture(); if once.claim() { continuation.resume(returning: image) } }
            Task { try? await Task.sleep(for: timeout); if once.claim() { continuation.resume(returning: nil) } }
        }
    }

    private final class Once: Sendable {
        private let taken = Mutex(false)
        func claim() -> Bool { taken.withLock { taken in defer { taken = true }; return !taken } }
    }

    private static func capture() async throws -> String? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pointer = CGEvent(source: nil)?.location ?? .zero
        guard let display = content.displays.first(where: { $0.frame.contains(pointer) }) ?? content.displays.first else { return nil }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let size = scaled(width: display.width, height: display.height)
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return jpeg(image).map { $0.base64EncodedString() }
    }

    /// The display's size with its long side capped at `maxSide`, keeping its shape.
    static func scaled(width: Int, height: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > maxSide, long > 0 else { return (width, height) }
        let ratio = Double(maxSide) / Double(long)
        return (max(1, Int((Double(width) * ratio).rounded())), max(1, Int((Double(height) * ratio).rounded())))
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
