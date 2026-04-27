import Foundation

struct SHDocumentPage: Codable, Hashable, Sendable {
    var pageIndex: Int
    var rawText: String
    var cleanedText: String
}

struct SHDocumentMetadata: Codable, Hashable, Sendable {
    var pageCount: Int
    var usedOCR: Bool
    var hasTextLayer: Bool
}

struct SHCachedDocument: Codable, Sendable {
    var sourceFile: String
    var fileHash: String
    var processedAt: Date
    var rawText: String
    var cleanedText: String
    var pages: [SHDocumentPage]
    var metadata: SHDocumentMetadata
}

struct SHPipelineCounters: Sendable {
    /// Total PDFs discovered by the scanner (preprocessing) or in-memory cached
    /// documents being processed (extraction).
    var foundPDFs: Int = 0
    /// Documents available in the cache for this run (preprocessing sets this to
    /// on-disk cache size; extraction sets it to the in-memory cachedDocuments count).
    var cachedDocs: Int = 0
    /// How many of the docs processed in the current run required OCR.
    var newlyOCRed: Int = 0
    var completed: Int = 0

    /// Documents still waiting for processing = `foundPDFs - completed`.
    /// Derived so the UI can't drift from completed – previously stored and had to
    /// be set manually in every loop iteration (easy to forget, which caused the
    /// "Rozpracováno: 0" bug during extraction).
    var remaining: Int { max(foundPDFs - completed, 0) }

    /// Back-compat alias – older call-sites (UI) use `inProgress` label.
    var inProgress: Int { remaining }
}

struct SHBenchmarkSnapshot: Codable, Sendable {
    var scanMs: Double = 0
    var ocrMs: Double = 0
    var textExtractionMs: Double = 0
    var inferenceMs: Double = 0
    /// Wall-clock duration of the whole run. Used for honest throughput numbers
    /// (the sum of phase timings double-counts pages that fall back from text
    /// extraction to OCR, so it's not a good denominator).
    var wallClockMs: Double = 0
    var totalPages: Int = 0
    var totalDocuments: Int = 0

    var avgPerPageMs: Double {
        guard totalPages > 0 else { return 0 }
        return (ocrMs + textExtractionMs + inferenceMs) / Double(totalPages)
    }

    var avgPerDocumentMs: Double {
        guard totalDocuments > 0 else { return 0 }
        return (scanMs + ocrMs + textExtractionMs + inferenceMs) / Double(totalDocuments)
    }

    /// docs / min measured against wall-clock time. Falls back to the summed phase
    /// duration if wall-clock wasn't recorded (older snapshots, tests).
    var throughputDocsPerMinute: Double {
        let denominator = wallClockMs > 0
            ? wallClockMs
            : (scanMs + ocrMs + textExtractionMs + inferenceMs)
        guard denominator > 0 else { return 0 }
        return (Double(totalDocuments) / denominator) * 60_000.0
    }
}
