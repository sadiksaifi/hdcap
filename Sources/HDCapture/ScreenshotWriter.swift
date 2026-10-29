import CoreImage
import CoreMedia
import Foundation
import Metal

public struct ScreenshotResult: Codable, Sendable {
    public let path: String
    public let width: Int
    public let height: Int
    public let bytes: Int
}

public enum ScreenshotWriter {
    /// The capture engine has already applied rotation and mirroring to this frame.
    /// Core Image reads the YUV surface through Metal; PNG encoding is a one-shot export.
    public static func write(sampleBuffer: CMSampleBuffer, to destination: URL,
                             overwrite: Bool = false) throws -> ScreenshotResult {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw CaptureError("invalid_frame", "The captured sample has no image buffer.")
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CaptureError("gpu_unavailable", "A Metal device is required to export a screenshot.")
        }
        let manager = FileManager.default
        guard overwrite || !manager.fileExists(atPath: destination.path) else {
            throw CaptureError("output_exists", "The output file already exists.", details: ["path": destination.path])
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".hdcap-\(UUID().uuidString).png")
        defer { try? manager.removeItem(at: temporary) }

        let context = CIContext(mtlCommandQueue: queue, options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false,
            .name: "hdcap screenshot",
        ])
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        do {
            try context.writePNGRepresentation(of: image, to: temporary, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            if overwrite, manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
            let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return ScreenshotResult(path: destination.path,
                                    width: CVPixelBufferGetWidth(pixelBuffer),
                                    height: CVPixelBufferGetHeight(pixelBuffer), bytes: bytes)
        } catch {
            throw CaptureError("screenshot_failed", "Could not write the PNG screenshot.",
                               details: ["path": destination.path, "reason": error.localizedDescription])
        }
    }
}
