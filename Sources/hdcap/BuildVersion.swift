enum BuildVersion {
    // Release packaging replaces this value with the validated tag version.
    static let release = "0.0.0"
    static var current: String {
        release == "0.0.0" ? "0.0.0-dev.\(GitRevision.current)" : release
    }
}
