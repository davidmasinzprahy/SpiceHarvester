import Foundation

/// Externí CLI nástroje volané z aplikace. `rawValue` == název spustitelného souboru.
enum SHTool: String, CaseIterable, Sendable {
    case pandoc
    case pdftotext
    case pdfinfo
    case in2csv

    var executableName: String { rawValue }
    var versionArguments: [String] { ["--version"] }
}

/// Výsledek spuštění nástroje.
struct SHToolResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum SHToolError: Error, Sendable {
    case notFound(SHTool)
    case timedOut(SHTool)
    case nonZeroExit(SHTool, code: Int32, stderr: String)
}
