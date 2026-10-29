import CoreImage
import CoreMedia
import Foundation
import Metal
import Testing
@testable import HDCapture

@Test func screenshotPreservesTransformedFrameAndProtectsExistingFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("frame.png")
    let device = try #require(MTLCreateSystemDefaultDevice())
    let context = CIContext(mtlDevice: device)

    // Asymmetric source: red left, green right, and a blue square at bottom-left.
    let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 48))
    let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
        .cropped(to: CGRect(x: 32, y: 0, width: 32, height: 48))
    let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 12, height: 12))
    let source = blue.composited(over: red.composited(over: green))
    // This represents the capture output after a clockwise rotation and horizontal flip.
    let transformed = source.transformed(by: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 48, 64, kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferMetalCompatibilityKey: true,
                                     kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    #expect(status == kCVReturnSuccess)
    let pixelBuffer = try #require(buffer)
    context.render(transformed, to: pixelBuffer)
    var description: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                        imageBuffer: pixelBuffer,
                                                        formatDescriptionOut: &description) == noErr)
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero,
                                    decodeTimeStamp: .invalid)
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                   imageBuffer: pixelBuffer,
                                                   formatDescription: try #require(description),
                                                   sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    let sampleBuffer = try #require(sample)
    let result = try ScreenshotWriter.write(sampleBuffer: sampleBuffer, to: destination)
    #expect(result.width == 48)
    #expect(result.height == 64)
    #expect(result.bytes > 0)
    let image = try #require(CIImage(contentsOf: destination))
    #expect(image.extent.size == CGSize(width: 48, height: 64))

    // These positions follow (x, y) -> (y, x), independently of the writer.
    func pixel(x: Int, y: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &rgba, rowBytes: 4,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return rgba
    }
    #expect(pixel(x: 4, y: 4) == [0, 0, 255, 255])
    #expect(pixel(x: 30, y: 16) == [255, 0, 0, 255])
    #expect(pixel(x: 30, y: 48) == [0, 255, 0, 255])
    let original = try Data(contentsOf: destination)
    #expect(throws: CaptureError.self) {
        try ScreenshotWriter.write(sampleBuffer: sampleBuffer, to: destination)
    }
    #expect(try Data(contentsOf: destination) == original)
    let replacement = try ScreenshotWriter.write(sampleBuffer: sampleBuffer, to: destination, overwrite: true)
    #expect(replacement.bytes > 0)
}
