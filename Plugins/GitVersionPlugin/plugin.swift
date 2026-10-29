import Foundation
import PackagePlugin

@main
struct GitVersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
        let output = context.pluginWorkDirectoryURL.appendingPathComponent("Generated")
        return [.prebuildCommand(
            displayName: "Generate Git revision",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"""
                revision=$(/usr/bin/git --no-optional-locks -C "$1" rev-parse --short=12 HEAD 2>/dev/null) || revision=unknown
                case "$revision" in ''|*[!0-9a-f]*) revision=unknown ;; esac
                mkdir -p "$2"
                printf 'enum GitRevision { static let current = "%s" }\n' "$revision" > "$2/GitRevision.swift.tmp"
                if ! cmp -s "$2/GitRevision.swift.tmp" "$2/GitRevision.swift"; then
                    mv "$2/GitRevision.swift.tmp" "$2/GitRevision.swift"
                fi
                rm -f "$2/GitRevision.swift.tmp"
                """#, "generate-git-revision", context.package.directoryURL.path, output.path],
            outputFilesDirectory: output
        )]
    }
}
