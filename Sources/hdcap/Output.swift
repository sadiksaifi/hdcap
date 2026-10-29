import ArgumentParser
import Foundation
import HDCapture

enum Output {
    private static let terminal = TerminalOutput()

    static var json: Bool {
        CommandLine.arguments.dropFirst().prefix { $0 != "--" }.contains("--json")
    }

    static var command: String {
        CommandLine.arguments.dropFirst().first { ["devices", "modes", "view", "record", "screenshot", "schema"].contains($0) } ?? "hdcap"
    }

    static func result<T: Encodable>(_ data: T, command: String, text: () -> String) throws {
        let bytes: Data
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let value = try encoder.encode(ResultEnvelope(command: command, data: data))
            bytes = value + Data([10])
        } else {
            bytes = Data((text() + "\n").utf8)
        }
        let status = terminal.finish(status: 0) { FileHandle.standardOutput.write(bytes) }
        if status != 0 { Darwin.exit(status) }
    }

    static func error(_ error: Error, parsing: Bool = false) -> Int32 {
        let captureError: CaptureError
        let code: Int32
        if let failure = error as? CaptureError {
            captureError = failure
            let signal = failure.details["signal"].flatMap(Int32.init)
            code = failure.code == "interrupted" ? 128 + (signal == SIGTERM ? SIGTERM : SIGINT) : 1
        } else if HDCap.exitCode(for: error).rawValue == 0 {
            return terminal.finish(status: 0) {
                FileHandle.standardOutput.write(Data((HDCap.fullMessage(for: error) + "\n").utf8))
            }
        } else if parsing {
            if !json {
                return terminal.finish(status: HDCap.exitCode(for: error).rawValue) {
                    FileHandle.standardError.write(Data((HDCap.fullMessage(for: error) + "\n").utf8))
                }
            }
            captureError = CaptureError("invalid_arguments", HDCap.message(for: error))
            code = HDCap.exitCode(for: error).rawValue
        } else {
            captureError = CaptureError("operation_failed", error.localizedDescription)
            code = 1
        }
        return terminal.finish(status: code) {
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                if let data = try? encoder.encode(ErrorEnvelope(command: command, error: captureError)) {
                    FileHandle.standardError.write(data + Data([10]))
                }
            } else {
                let details = captureError.details.keys.sorted().map { "  \($0): \(captureError.details[$0]!)\n" }.joined()
                FileHandle.standardError.write(Data("Error: \(captureError.message)\n\(details)".utf8))
            }
        }
    }

    static func notice(_ text: String) {
        guard !json else { return }
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// The first terminal outcome owns both the output stream and the process status.
private final class TerminalOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?

    func finish(status requested: Int32, write: () -> Void) -> Int32 {
        lock.withLock {
            if let status { return status }
            status = requested
            write()
            return requested
        }
    }
}

private struct ResultEnvelope<T: Encodable>: Encodable {
    let schema_version = 1
    let command: String
    let data: T
}

private struct ErrorEnvelope: Encodable {
    let schema_version = 1
    let command: String
    let error: CaptureError
}

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print a versioned JSON result; print JSON errors to stderr.")
    var json = false
}

func table(_ headers: [String], rows: [[String]]) -> String {
    let widths = headers.indices.map { column in
        ([headers[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
    }
    return ([headers] + rows).map { row in
        row.enumerated().map { column, value in
            column == row.count - 1 ? value : value.padding(toLength: widths[column] + 2, withPad: " ", startingAt: 0)
        }.joined()
    }.joined(separator: "\n")
}
