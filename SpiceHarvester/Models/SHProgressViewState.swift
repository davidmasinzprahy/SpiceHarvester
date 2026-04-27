import Foundation

/// Which pipeline stage the UI should render progress for. Set by the view
/// model on run start and flipped to `.finished` when the run exits (regardless
/// of success / cancel / fail – the exact outcome is carried by `lastCompletion`).
enum SHProgressPhase: Sendable {
    case idle
    case preprocessing
    case extraction
    case finished
}

/// Derived health status for the progress card indicator.
/// `starting` covers the grace window right after a run begins (scan + server
/// warmup) so the indicator doesn't flash "stuck" before the first counter
/// increment. `stuck` means the pipeline stopped reporting progress for longer
/// than the silence threshold – typical causes: LM Studio hang, network drop,
/// OCR on an unusually large page.
enum SHProgressHealth: Sendable {
    case idle
    case starting
    case ok
    case stuck
    case finished
}

struct SHProgressViewState: Sendable {
    var counters: SHPipelineCounters = .init()
    var startedAt: Date?
    /// Timestamp of the last counter increment. Used by `health(now:)` to detect
    /// a silent pipeline. `nil` means no counter has moved yet in this run.
    var lastProgressAt: Date?
    var phase: SHProgressPhase = .idle
    /// Display progress for the active extraction sub-phase. Usually documents,
    /// but in CONSOLIDATE map-reduce it becomes "LM steps" (batches + reduce).
    var extractionProgressCompleted: Int = 0
    var extractionProgressTotal: Int = 0
    var extractionProgressLabel: String?
    var averageDocumentSeconds: Double = 0
    var etaSeconds: Double = 0

    var remainingDocuments: Int {
        max(counters.foundPDFs - counters.completed, 0)
    }

    /// Progress of the currently running phase as 0...1. Preprocessing tracks
    /// `cachedDocs / foundPDFs` (docs written to the on-disk cache so far);
    /// extraction tracks `completed / foundPDFs`.
    var currentPhasePercent: Double {
        switch phase {
        case .idle: return 0
        case .finished: return 1
        case .preprocessing:
            guard counters.foundPDFs > 0 else { return 0 }
            return min(1, Double(counters.cachedDocs) / Double(counters.foundPDFs))
        case .extraction:
            guard extractionProgressTotal > 0 else { return 0 }
            return min(1, Double(extractionProgressCompleted) / Double(extractionProgressTotal))
        }
    }

    /// "12 / 16" style counter for the current phase.
    var currentPhaseCountText: String {
        switch phase {
        case .idle: return "—"
        case .preprocessing:
            return "\(counters.cachedDocs) / \(counters.foundPDFs)"
        case .extraction:
            let base = "\(extractionProgressCompleted) / \(extractionProgressTotal)"
            guard let extractionProgressLabel else { return base }
            return "\(base) \(extractionProgressLabel)"
        case .finished:
            return "\(counters.completed) / \(counters.foundPDFs)"
        }
    }

    var phaseTitle: String {
        switch phase {
        case .idle: return "Připraveno"
        case .preprocessing: return "Předzpracování (OCR + extrakce textu)"
        case .extraction: return "Extrakce (AI inference)"
        case .finished: return "Dokončeno"
        }
    }

    /// Human-friendly ETA: "45 s", "~3 min 12 s", "~1 h 5 min", or "—".
    var etaHuman: String {
        guard etaSeconds > 0 else { return "—" }
        let sec = Int(etaSeconds.rounded())
        if sec < 60 { return "~\(sec) s" }
        let m = sec / 60
        let s = sec % 60
        if m < 60 { return s == 0 ? "~\(m) min" : "~\(m) min \(s) s" }
        let h = m / 60
        let mm = m % 60
        return "~\(h) h \(mm) min"
    }

    func elapsedSeconds(now: Date = Date()) -> Double {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Seconds since the last counter increment, or `.infinity` if no progress
    /// has been reported in the current run yet.
    func secondsSinceLastProgress(now: Date = Date()) -> Double {
        guard let lastProgressAt else { return .infinity }
        return max(0, now.timeIntervalSince(lastProgressAt))
    }

    /// Health heuristic.
    /// - `stuckAfter`: silence threshold (seconds) after which a still-running
    ///   pipeline is considered stuck. 30s covers normal OCR/inference times.
    /// - `graceAfter`: startup grace window so "no progress yet" during the first
    ///   scan doesn't immediately trigger a warning.
    func health(now: Date = Date(),
                stuckAfter: Double = 30,
                graceAfter: Double = 15) -> SHProgressHealth {
        switch phase {
        case .idle: return .idle
        case .finished: return .finished
        case .preprocessing, .extraction:
            let silent = secondsSinceLastProgress(now: now)
            if silent == .infinity {
                return elapsedSeconds(now: now) < graceAfter ? .starting : .stuck
            }
            return silent > stuckAfter ? .stuck : .ok
        }
    }
}
