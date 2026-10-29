import Testing
@testable import HDCapture

@Test func nativeMirrorBeforeRotationMatchesClockwiseThenOutputFlips() throws {
    // Distinct values identify all six source coordinates in an asymmetric frame.
    let source = [[1, 2, 3], [4, 5, 6]]
    let clockwiseRotations: [(Int, [[Int]])] = [
        (0, [[1, 2, 3], [4, 5, 6]]),
        (90, [[4, 1], [5, 2], [6, 3]]),
        (180, [[6, 5, 4], [3, 2, 1]]),
        (270, [[3, 6], [2, 5], [1, 4]]),
    ]
    for (angle, rotated) in clockwiseRotations {
        for flip in Flip.allCases {
            let transform = try VideoTransform(rotation: angle, flip: flip)
            var expected = rotated
            if flip == .horizontal || flip == .both { expected = expected.map { Array($0.reversed()) } }
            if flip == .vertical || flip == .both { expected.reverse() }

            // Simulate the hardware's observed order: source-axis mirror, then rotation.
            var native = transform.nativeMirrored ? source.map { Array($0.reversed()) } : source
            for _ in 0..<(transform.nativeRotation / 90) {
                native = (0..<native[0].count).map { x in native.reversed().map { $0[x] } }
            }
            #expect(native == expected, "rotation=\(angle), flip=\(flip.rawValue)")
        }
    }
}
