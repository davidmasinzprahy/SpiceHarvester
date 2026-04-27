import Foundation

actor SHBenchmarkService {
    private var snapshot = SHBenchmarkSnapshot()
    private var runStart: Date?

    func addScan(durationMs: Double, docs: Int) {
        snapshot.scanMs += durationMs
        snapshot.totalDocuments = max(snapshot.totalDocuments, docs)
        if runStart == nil { runStart = Date() }
    }

    /// Previously `addOCR` and `addTextExtraction` both incremented `totalPages`,
    /// so any page that fell back from text extraction to OCR was counted twice
    /// and `avgPerPageMs` was too optimistic. We now track total pages only once,
    /// explicitly, via `recordPages(_:)`.
    func addOCR(durationMs: Double, pages: Int) {
        snapshot.ocrMs += durationMs
        if runStart == nil { runStart = Date() }
        _ = pages // pages are accounted for in `recordPages`
    }

    func addTextExtraction(durationMs: Double, pages: Int) {
        snapshot.textExtractionMs += durationMs
        if runStart == nil { runStart = Date() }
        _ = pages
    }

    /// Should be called once per document with the document's authoritative page count.
    func recordPages(_ pages: Int) {
        snapshot.totalPages += pages
    }

    func addInference(durationMs: Double) {
        snapshot.inferenceMs += durationMs
        if runStart == nil { runStart = Date() }
    }

    /// Call when the benchmark snapshot is read by the UI. Sets `wallClockMs` to the
    /// elapsed time since the first phase was recorded, providing an honest throughput.
    func current() -> SHBenchmarkSnapshot {
        var copy = snapshot
        if let runStart {
            copy.wallClockMs = Date().timeIntervalSince(runStart) * 1000.0
        }
        return copy
    }

    func reset() {
        snapshot = SHBenchmarkSnapshot()
        runStart = nil
    }
}
