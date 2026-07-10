import Foundation
import ScreenCaptureKit
import CoreImage

/// Grabs a screenshot of the main display via ScreenCaptureKit (macOS 14+).
/// The base64 PNG is what you'd hand to Claude vision for "click the blue button"
/// style commands once the AX-tree search comes up empty. Requires the app to be
/// granted Screen Recording in System Settings.
enum ScreenCapture {

    enum CaptureError: Error { case noDisplay, encodeFailed }

    /// Returns a downscaled PNG of the main display, base64-encoded for the Messages API.
    static func mainDisplayPNGBase64(maxWidth: Int = 1512) async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1.0, Double(maxWidth) / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let ci = CIImage(cgImage: image)
        let context = CIContext()
        guard let png = context.pngRepresentation(of: ci,
                                                   format: .RGBA8,
                                                   colorSpace: ci.colorSpace ?? CGColorSpaceCreateDeviceRGB()) else {
            throw CaptureError.encodeFailed
        }
        return png.base64EncodedString()
    }
}
