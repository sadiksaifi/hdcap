import Testing
@testable import HDCapture

@Test func selectsFastNativeFormatInsteadOfLastResolutionMatch() throws {
    let formats = [
        ModeInfo(id: "fast", index: 0, width: 1280, height: 720, pixelFormat: "420v",
                 frameRateRanges: [.init(min: 5, max: 60)]),
        ModeInfo(id: "raw", index: 1, width: 1280, height: 720, pixelFormat: "yuvs",
                 frameRateRanges: [.init(min: 5, max: 10)]),
    ]
    let resolution = try Resolution("1280x720")
    #expect(try DeviceCatalog.selectMode(from: formats, resolution: resolution, frameRate: FrameRate("60")).id == "fast")
    #expect(try DeviceCatalog.selectMode(from: formats, resolution: resolution, frameRate: FrameRate("10")).id == "fast")
}

@Test func rejectsUnsupportedFrameRateWithoutChangingResolution() throws {
    let formats = [
        ModeInfo(id: "1080p25", index: 0, width: 1920, height: 1080, pixelFormat: "420v",
                 frameRateRanges: [.init(min: 25, max: 25)]),
        ModeInfo(id: "720p60", index: 1, width: 1280, height: 720, pixelFormat: "420v",
                 frameRateRanges: [.init(min: 60, max: 60)]),
    ]
    #expect(throws: CaptureError.self) {
        try DeviceCatalog.selectMode(from: formats, resolution: Resolution("1920x1080"), frameRate: FrameRate("60"))
    }
}

@Test func preservesFractionalFrameRateAndRejectsNearbyIntegerRate() throws {
    let formats = [ModeInfo(id: "ntsc", index: 0, width: 1280, height: 720, pixelFormat: "420v",
                            frameRateRanges: [.init(min: 60000.0 / 1001, max: 60000.0 / 1001)])]
    #expect(try DeviceCatalog.selectMode(from: formats, resolution: Resolution("1280x720"), frameRate: FrameRate("59.94")).id == "ntsc")
    #expect(throws: CaptureError.self) {
        try DeviceCatalog.selectMode(from: formats, resolution: Resolution("1280x720"), frameRate: FrameRate("60"))
    }
}
