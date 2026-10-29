import Testing
@testable import HDCapture

@Test("Fractional frame rates preserve exact NTSC timing")
func fractionalFrameRates() throws {
    let decimal = try FrameRate("59.94")
    let rational = try FrameRate("60000/1001")
    #expect(decimal == rational)
    #expect(decimal.frameDuration.value == 1001)
    #expect(decimal.frameDuration.timescale == 60000)
    #expect(try FrameRate("60").frameDuration.timescale == 60)
    #expect(try FrameRate("12.5").value == 12.5)
}

@Test("Invalid frame rates fail before configuring a device", arguments: ["0", "-1", "nan", "inf", "60/0", "1/2/3", "1001", "0.00000001"])
func invalidFrameRates(text: String) {
    #expect(throws: CaptureError.self) { try FrameRate(text) }
}

@Test("Resolution parsing rejects invalid and excessive dimensions", arguments: ["1920", "0x720", "1280x-1", "1280x720x60", "999999999999x720"])
func invalidResolutions(text: String) {
    #expect(throws: CaptureError.self) { try Resolution(text) }
}

@Test("Quarter turns swap the output axes")
func rotationAxes() throws {
    #expect(try VideoTransform(rotation: 90).swapsDimensions)
    #expect(try VideoTransform(rotation: 270).swapsDimensions)
    #expect(try !VideoTransform(rotation: 180).swapsDimensions)
    #expect(throws: CaptureError.self) { try VideoTransform(rotation: 45) }
}
