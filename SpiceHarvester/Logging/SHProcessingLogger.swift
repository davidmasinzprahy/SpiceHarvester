import Foundation

/// Append-only processing log.
///
/// Optimizations over the previous design:
/// - Caches a single `FileHandle` for the lifetime of the logger instead of
///   opening / closing on every `log(...)` call. For batched pipelines this
///   cuts syscall count by ~2×.
/// - `readTail(maxLines:)` reads from the end of the file instead of slurping
///   the whole log into memory (safe for long-running sessions).
actor SHProcessingLogger {
    private let fileURL: URL
    private var handle: FileHandle?
    /// ISO-8601 formatter pinned to the user's local timezone. Default for
    /// `ISO8601DateFormatter` is UTC (trailing `Z`), which was confusing because the
    /// log timestamps didn't match what the user saw on the clock.
    /// Output shape: `2026-04-16T12:27:42.237+02:00`.
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    init(logFileURL: URL) {
        self.fileURL = logFileURL
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            try? "timestamp | level | file | phase | message | duration_ms\n"
                .write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    deinit {
        // Actor deinit can't be async; close synchronously. Safe because handle is
        // a value actor-isolated to this instance.
        try? handle?.close()
    }

    func log(level: String = "INFO", file: String, phase: String, message: String, durationMs: Double? = nil) {
        let ts = formatter.string(from: Date())
        let durationString = durationMs.map { String(format: "%.0f", $0) } ?? ""
        // Escape pipe separators inside free-text fields so the CSV-like format
        // remains parseable. Newlines are replaced with spaces for the same reason.
        let safeFile = escape(file)
        let safePhase = escape(phase)
        let safeMessage = escape(message)
        let line = "\(ts) | \(level) | \(safeFile) | \(safePhase) | \(safeMessage) | \(durationString)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            let h = try ensureHandle()
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } catch {
            // Drop cached handle – next call will try to reopen. Silent fail is
            // acceptable for logging; surfacing here would cause feedback loops.
            try? handle?.close()
            handle = nil
        }
    }

    /// Reads up to `maxLines` most recent lines from the end of the log.
    /// Does NOT load the whole file – reads a trailing window.
    func readTail(maxLines: Int = 300) -> String {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? fh.close() }

        do {
            // Read the last ~256 KB or the whole file, whichever is smaller. Enough
            // room for several hundred lines even with verbose messages.
            let size = try fh.seekToEnd()
            let windowSize: UInt64 = 256 * 1024
            let start = size > windowSize ? size - windowSize : 0
            try fh.seek(toOffset: start)
            guard let data = try fh.readToEnd(), let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(maxLines).joined(separator: "\n")
        } catch {
            return ""
        }
    }

    // MARK: – Private

    private func ensureHandle() throws -> FileHandle {
        if let handle { return handle }
        // The init already guaranteed the file exists (wrote the header), but
        // another process may have removed it. Recreate if needed.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try "timestamp | level | file | phase | message | duration_ms\n"
                .write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let h = try FileHandle(forWritingTo: fileURL)
        handle = h
        return h
    }

    private func escape(_ field: String) -> String {
        field
            .replacingOccurrences(of: "|", with: "¦") // broken bar = won't collide in practice
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
