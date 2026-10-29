import ArgumentParser
import Foundation

struct Schema: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the JSON Schema for results and errors. This command does not access hardware.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        let data = Data(Self.document.utf8)
        let schema = try JSONSerialization.jsonObject(with: data)
        let result: Any = Output.json ? ["schema_version": 1, "command": "schema", "data": schema] : schema
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(encoded + Data([10]))
    }

    private static let document = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "title": "hdcap version 1 results and errors",
      "type": "object",
      "required": ["schema_version", "command"],
      "properties": {
        "schema_version": {"const": 1},
        "command": {"enum": ["hdcap", "devices", "modes", "view", "record", "screenshot", "schema"]}
      },
      "oneOf": [
        {"required": ["error"], "properties": {"error": {"$ref": "#/$defs/error"}}, "not": {"required": ["data"]}},
        {"required": ["data"], "not": {"required": ["error"]}, "allOf": [
          {"if": {"properties": {"command": {"const": "devices"}}}, "then": {"properties": {"data": {"type": "array", "items": {"$ref": "#/$defs/device"}}}}},
          {"if": {"properties": {"command": {"const": "modes"}}}, "then": {"properties": {"data": {"type": "array", "items": {"$ref": "#/$defs/mode"}}}}},
          {"if": {"properties": {"command": {"const": "view"}}}, "then": {"properties": {"data": {"$ref": "#/$defs/view"}}}},
          {"if": {"properties": {"command": {"const": "record"}}}, "then": {"properties": {"data": {"$ref": "#/$defs/record"}}}},
          {"if": {"properties": {"command": {"const": "screenshot"}}}, "then": {"properties": {"data": {"$ref": "#/$defs/screenshot"}}}},
          {"if": {"properties": {"command": {"const": "schema"}}}, "then": {"properties": {"data": {"type": "object", "required": ["$schema", "$defs"]}}}}
        ]}
      ],
      "$defs": {
        "error": {"type": "object", "required": ["code", "message", "details"], "properties": {
          "code": {"type": "string"}, "message": {"type": "string"}, "details": {"type": "object", "additionalProperties": {"type": "string"}}
        }},
        "device": {"type": "object", "required": ["id", "name", "manufacturer", "modelID", "transportType"], "properties": {
          "id": {"type": "string"}, "name": {"type": "string"}, "manufacturer": {"type": "string"}, "modelID": {"type": "string"}, "transportType": {"type": "string"}
        }},
        "frameRate": {"type": "object", "required": ["numerator", "denominator"], "properties": {
          "numerator": {"type": "integer", "minimum": 1}, "denominator": {"type": "integer", "minimum": 1}
        }},
        "mode": {"type": "object", "required": ["id", "index", "width", "height", "pixelFormat", "frameRateRanges", "recommended"], "properties": {
          "id": {"type": "string"}, "index": {"type": "integer"}, "width": {"type": "integer", "minimum": 1}, "height": {"type": "integer", "minimum": 1},
          "pixelFormat": {"type": "string"}, "recommended": {"type": "boolean"}, "frameRateRanges": {"type": "array", "items": {"type": "object", "required": ["min", "max"], "properties": {"min": {"type": "number"}, "max": {"type": "number"}}}}
        }},
        "capture": {"type": "object", "required": ["device", "mode", "frameRate", "actualFrameRate", "effectiveFrameDuration", "outputWidth", "outputHeight", "rotation", "mirrored"], "properties": {
          "device": {"$ref": "#/$defs/device"}, "mode": {"$ref": "#/$defs/mode"}, "frameRate": {"$ref": "#/$defs/frameRate"},
          "actualFrameRate": {"type": "number", "exclusiveMinimum": 0},
          "effectiveFrameDuration": {"type": "object", "required": ["value", "timescale"], "properties": {"value": {"type": "integer", "minimum": 1}, "timescale": {"type": "integer", "minimum": 1}}},
          "outputWidth": {"type": "integer", "minimum": 1}, "outputHeight": {"type": "integer", "minimum": 1}, "rotation": {"enum": [0, 90, 180, 270]}, "mirrored": {"type": "boolean"}
        }},
        "statistics": {"type": "object", "required": ["framesReceived", "framesDropped", "measuredFPS", "firstFrameReceived", "elapsedSeconds"], "properties": {
          "framesReceived": {"type": "integer", "minimum": 0}, "framesDropped": {"type": "integer", "minimum": 0}, "measuredFPS": {"type": "number", "minimum": 0},
          "firstFrameReceived": {"type": "boolean"}, "elapsedSeconds": {"type": "number", "minimum": 0}, "iosurfaceBacked": {"type": "boolean"},
          "pixelFormat": {"type": "string"}, "width": {"type": "integer", "minimum": 1}, "height": {"type": "integer", "minimum": 1}
        }},
        "view": {"type": "object", "required": ["capture", "statistics", "stoppedBy"], "properties": {
          "capture": {"$ref": "#/$defs/capture"}, "statistics": {"$ref": "#/$defs/statistics"}, "stoppedBy": {"enum": ["duration", "window_closed", "sigint", "sigterm"]}
        }},
        "record": {"type": "object", "required": ["capture", "statistics", "stoppedBy", "movie"], "properties": {
          "capture": {"$ref": "#/$defs/capture"}, "statistics": {"$ref": "#/$defs/statistics"}, "stoppedBy": {"enum": ["duration", "sigint", "sigterm"]},
          "movie": {"type": "object", "required": ["path", "codec", "hardwareRequired", "framesWritten", "framesDropped", "duration", "sizeBytes", "resolution", "frameRate"], "properties": {
            "path": {"type": "string"}, "codec": {"enum": ["h264", "hevc"]}, "hardwareRequired": {"const": true}, "framesWritten": {"type": "integer", "minimum": 1},
            "framesDropped": {"type": "integer", "minimum": 0}, "duration": {"type": "number", "minimum": 0}, "sizeBytes": {"type": "integer", "minimum": 1}, "frameRate": {"$ref": "#/$defs/frameRate"},
            "resolution": {"type": "object", "required": ["width", "height"], "properties": {"width": {"type": "integer", "minimum": 1}, "height": {"type": "integer", "minimum": 1}}}
          }}
        }},
        "screenshot": {"type": "object", "required": ["capture", "statistics", "image"], "properties": {
          "capture": {"$ref": "#/$defs/capture"}, "statistics": {"$ref": "#/$defs/statistics"}, "image": {"type": "object", "required": ["path", "width", "height", "bytes"], "properties": {
            "path": {"type": "string"}, "width": {"type": "integer", "minimum": 1}, "height": {"type": "integer", "minimum": 1}, "bytes": {"type": "integer", "minimum": 1}
          }}
        }}
      }
    }
    """#
}
