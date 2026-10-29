import ArgumentParser
import Foundation
import HDCapture

enum Output {
    static var json: Bool {
        CommandLine.arguments.dropFirst().prefix { $0 != "--" }.contains("--json")
    }

    static var command: String {
        CommandLine.arguments.dropFirst().first { ["devices", "modes", "view", "record", "screenshot", "schema"].contains($0) } ?? "hdcap"
    }

    static func result<T: Encodable>(_ data: T, command: String, text: () -> String) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let value = try encoder.encode(ResultEnvelope(command: command, data: data))
            FileHandle.standardOutput.write(value + Data([10]))
        } else {
            print(text())
        }
    }

    static func error(_ error: Error, parsing: Bool = false) -> Int32 {
        let captureError: CaptureError
        let code: Int32
        if let failure = error as? CaptureError {
            captureError = failure
            code = failure.code == "interrupted" ? 130 : 1
        } else if HDCap.exitCode(for: error).rawValue == 0 {
            HDCap.exit(withError: error)
        } else if parsing {
            if !json { HDCap.exit(withError: error) }
            captureError = CaptureError("invalid_arguments", HDCap.message(for: error))
            code = HDCap.exitCode(for: error).rawValue
        } else {
            captureError = CaptureError("operation_failed", error.localizedDescription)
            code = 1
        }
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
        return code
    }

    static func notice(_ text: String) {
        guard !json else { return }
        FileHandle.standardError.write(Data((text + "\n").utf8))
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
