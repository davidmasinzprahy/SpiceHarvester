import Foundation

struct SHToolRuntime: Sendable {
    let helpersDirectory: URL?
    let pathDirectories: [URL]

    init(
        helpersDirectory: URL? = SHToolRuntime.defaultHelpersDirectory,
        pathDirectories: [URL] = SHToolRuntime.defaultPathDirectories
    ) {
        self.helpersDirectory = helpersDirectory
        self.pathDirectories = pathDirectories
    }

    /// Bundlovaná binárka má přednost před PATH (PATH je jen vývojová pohodlnost).
    func resolve(_ tool: SHTool) -> URL? {
        let fm = FileManager.default
        if let helpers = helpersDirectory {
            let candidate = helpers.appendingPathComponent(tool.executableName)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        for dir in pathDirectories {
            let candidate = dir.appendingPathComponent(tool.executableName)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static var defaultHelpersDirectory: URL? {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    static var defaultPathDirectories: [URL] {
        let raw = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return raw.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }
}
