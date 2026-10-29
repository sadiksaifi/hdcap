import CryptoKit
import Foundation
import HDCapture

/// Downloads assets from a stable GitHub release and checks them against its checksums.txt.
enum ReleaseAssets {
    static func base(tag: String) -> URL {
        URL(string: "https://github.com/sadiksaifi/hdcap/releases/download/\(tag)")!
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }

    static func download(_ url: URL, session: URLSession, failure code: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("hdcap", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https" else {
            throw CaptureError(code, "Cannot download a stable hdcap release.", details: ["url": url.absoluteString])
        }
        return data
    }

    /// Accepts the asset only when checksums.txt lists it exactly once with a matching SHA-256.
    static func verify(_ data: Data, named name: String, checksums: Data) throws {
        guard let text = String(data: checksums, encoding: .utf8) else {
            throw CaptureError("invalid_checksum", "The release checksum file is not UTF-8.")
        }
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[1] == name ? String(fields[0]) : nil
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard matches.count == 1, matches[0] == digest else {
            throw CaptureError("checksum_mismatch", "The release asset \(name) failed SHA-256 verification.")
        }
    }
}

struct StableVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init(_ text: String) throws {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ field in
            !field.isEmpty && field.allSatisfy(\.isASCII) && field.allSatisfy(\.isNumber) &&
            (field.count == 1 || field.first != "0") && Int(field) != nil
        }) else {
            throw CaptureError("invalid_release", "Upgrade requires a stable semantic version.")
        }
        components = fields.map { Int($0)! }
    }

    var description: String { components.map(String.init).joined(separator: ".") }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}
