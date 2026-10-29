import AVFoundation
import CoreVideo
import Testing
@testable import HDCapture

@Test(arguments: VideoCodec.allCases)
func recordsNativeBuffersWithCaptureTiming(codec: VideoCodec) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = try MovieRecorder(options: RecordingOptions(
        url: url, codec: codec, resolution: Resolution(width: 320, height: 240),
        frameRate: FrameRate(numerator: 30, denominator: 1)
    ))
    for index in 0..<6 {
        let sample = try testSample(index: index)
        recorder.append(sample)
        try await Task.sleep(for: .milliseconds(50))
    }
    let result = try await recorder.finish()
    #expect(result.framesWritten == 6)
    #expect(result.framesDropped == 0)
    #expect(result.sizeBytes > 0)
    #expect(result.hardwareRequired)
    #expect(abs(result.duration - 0.2) < 0.001)

    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == (codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC))
    #expect(CMVideoFormatDescriptionGetDimensions(format).width == 320)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    let provider = reader.outputProvider(for: output)
    try reader.start()
    var timestamps: [Double] = []
    var brightness: [UInt8] = []
    while let sample = try await provider.next() {
        guard case .pixelBuffer(let pixels) = sample.content else { continue }
        timestamps.append(sample.presentationTimeStamp.seconds)
        brightness.append(pixels.withUnsafeBuffer { buffer in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            return CVPixelBufferGetBaseAddress(buffer)!.load(as: UInt8.self)
        })
    }
    #expect(reader.status == .completed)
    #expect(timestamps.count == 6)
    #expect(abs(try #require(timestamps.first)) < 0.001)
    #expect(abs(try #require(timestamps.last) - 5.0 / 30) < 0.001)
    #expect(zip(brightness, brightness.dropFirst()).allSatisfy { Int($1) - Int($0) > 10 })
}

@Test func refusesExistingOutput() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    try Data("preserve me".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: CaptureError.self) {
        try MovieRecorder(options: RecordingOptions(
            url: url, resolution: Resolution(width: 320, height: 240),
            frameRate: FrameRate(numerator: 30, denominator: 1)
        ))
    }
    #expect(try Data(contentsOf: url) == Data("preserve me".utf8))
}

@Test func preservesExistingOutputUntilReplacementCompletes() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    let previous = Data("previous recording".utf8)
    try previous.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = try MovieRecorder(options: RecordingOptions(
        url: url, resolution: Resolution(width: 320, height: 240),
        frameRate: FrameRate(numerator: 30, denominator: 1), overwrite: true
    ))
    recorder.append(try testSample(index: 0))
    #expect(try Data(contentsOf: url) == previous)
    let result = try await recorder.finish()
    #expect(result.framesWritten == 1)
    #expect(try Data(contentsOf: url) != previous)
}

private func testSample(index: Int) throws -> CMSampleBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    #expect(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              attributes, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    for plane in 0..<2 {
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
        memset(base, plane == 0 ? Int32(32 + index * 20) : 128,
               CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    var description: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                                                       formatDescriptionOut: &description) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                    presentationTimeStamp: CMTime(value: 300 + Int64(index), timescale: 30),
                                    decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
                                                    formatDescription: try #require(description),
                                                    sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}
