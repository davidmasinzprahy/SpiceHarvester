import Foundation
import SwiftUI
import AppKit
import Observation
import UserNotifications

/// Outcome classification for the most recent run. Drives the completion badge
/// shown in the Actions bar ("Hotovo", "Přerušeno", "Selhalo").
enum SHRunCompletion: Equatable, Sendable {
    case success
    case cancelled
    case failed
}

/// Typed return value from `performPreprocessing` / `performExtraction`.
/// Replaces the previous approach of classifying outcome by pattern-matching
/// `statusText.lowercased()`, which mis-classified guards like "Vyber vstupní
/// složku" as successful runs and made adding new status messages unsafe.
enum SHRunOutcome: Sendable {
    /// Work started and finished successfully.
    case success
    /// Work started but was cancelled by the user.
    case cancelled
    /// Work started but raised a non-cancellation error.
    case failed
    /// Pre-condition not met; nothing ran. Should NOT trigger a completion badge.
    case notStarted
}

enum SHRunConfigurationError: LocalizedError {
    case missingOCRServer
    case missingOCRModel

    var errorDescription: String? {
        switch self {
        case .missingOCRServer:
            return "Pro oMLX/VLM OCR vyber a ověř lokální AI server"
        case .missingOCRModel:
            return "Pro oMLX/VLM OCR vyber OCR/VLM model"
        }
    }
}

enum SHPromptThinkingMode: Equatable, Sendable {
    case noThinking
    case thinking
}

/// One row of the onboarding checklist shown above the configuration cards while
/// any prerequisite is missing. Each step is tied to a `hasX` predicate on the
/// view model so the row "checks itself" the moment the user fills the value in.
struct SHSetupStep: Identifiable, Sendable {
    let id: String
    let title: String
    let hint: String
    let isDone: Bool
}

/// Categorical key for the folder Recents store. Stable raw values so
/// UserDefaults keys don't drift if we add new folder slots later.
enum SHFolderKind: String, Codable, Hashable, CaseIterable, Sendable {
    case input, output, cache, prompt
}

/// Snapshot of everything that defines a "project" — folders, server
/// selection, model picks, prompt, mode. Excluded:
///   - server registry (URL+API key, kept globally so switching project
///     doesn't blow away access to all my servers)
///   - runtime state (isRunning, logs, lastCompletion)
///   - performance prefs (concurrency, timeout — global tuning)
/// JSON-encoded; written via NSSavePanel from `SHAppViewModel.saveProjectAs`.
/// Pragmatic stand-in for full DocumentGroup (see `docs/P2_BACKLOG_DEFERRED.md`).
struct SHProjectSnapshot: Codable, Sendable {
    var inputFolder: String
    var outputFolder: String
    var cacheFolder: String
    var promptFolder: String
    var selectedInferenceModel: String
    var selectedEmbeddingModel: String
    var selectedRerankerModel: String
    var selectedOCRModel: String
    var extractionMode: SHExtractionMode
    var currentPrompt: String
    var lastLoadedPromptName: String
    var schemaVersion: Int

    init(
        inputFolder: String,
        outputFolder: String,
        cacheFolder: String,
        promptFolder: String,
        selectedInferenceModel: String,
        selectedEmbeddingModel: String,
        selectedRerankerModel: String,
        selectedOCRModel: String,
        extractionMode: SHExtractionMode,
        currentPrompt: String,
        lastLoadedPromptName: String,
        schemaVersion: Int = 1
    ) {
        self.inputFolder = inputFolder
        self.outputFolder = outputFolder
        self.cacheFolder = cacheFolder
        self.promptFolder = promptFolder
        self.selectedInferenceModel = selectedInferenceModel
        self.selectedEmbeddingModel = selectedEmbeddingModel
        self.selectedRerankerModel = selectedRerankerModel
        self.selectedOCRModel = selectedOCRModel
        self.extractionMode = extractionMode
        self.currentPrompt = currentPrompt
        self.lastLoadedPromptName = lastLoadedPromptName
        self.schemaVersion = schemaVersion
    }
}

/// Errors specific to the Save / Load Project feature. Surfaced to the
/// view layer through `SHOpenProjectOutcome.failed(error:)` and
/// rendered as user-readable text in the "Otevření projektu selhalo"
/// alert. JSON decoding errors from `JSONDecoder` are intentionally
/// passed through as-is — they're already descriptive enough.
enum SHProjectError: LocalizedError {
    case notAProject(url: URL)
    /// Read failed with a sandbox permission error AND we have no
    /// working security-scoped bookmark for the path. Tells the user
    /// the specific remediation (re-pick the file via Cmd+O) instead
    /// of the generic "neoprávněný přístup" alert.
    case permissionDenied(url: URL)

    var errorDescription: String? {
        switch self {
        case .notAProject(let url):
            return "Soubor \(url.lastPathComponent) není projekt Spice Harvester. Otevři soubor exportovaný přes Uložit projekt jako…"
        case .permissionDenied(let url):
            return "Cesta \(url.lastPathComponent) vyžaduje opětovné udělení přístupu. macOS sandbox neuchovává oprávnění mezi spuštěními bez platného bookmarku. Otevři soubor znovu přes File → Otevřít projekt… (Cmd+O)."
        }
    }
}

/// Result of `SHAppViewModel.openProject`. The view layer matches on
/// these to show appropriate UI:
///   - `success`: silent; statusBar gets the message
///   - `successNeedsRepick`: alert listing folders that need re-Vybrat
///     because their security-scoped bookmark wasn't found in the
///     existing registry
///   - `failed`: alert with error text
///   - `cancelled`: user dismissed NSOpenPanel; no UI feedback needed
enum SHOpenProjectOutcome {
    case success(url: URL)
    case successNeedsRepick(url: URL, stalePaths: [String])
    case failed(error: Error)
    case cancelled
}

@MainActor
@Observable
final class SHAppViewModel {
    var config: SHAppConfig
    var servers: [SHServerConfig]
    var availableModels: [String] = []
    /// `.md` files discovered in the prompt folder. Populated by `reloadPromptFiles()`.
    var availablePromptFiles: [URL] = []
    /// Currently selected file in the prompt picker (if any).
    var selectedPromptFile: URL?
    var benchmark: SHBenchmarkSnapshot = .init()
    var progressState: SHProgressViewState = .init()
    var logText: String = ""
    var statusText: String = SHAppViewModel.idleStatus
    /// True while `statusText` matches the canonical idle message
    /// (`Self.idleStatus`). Decouples the status-bar-collapse logic
    /// from a hard-coded literal so localization can swap the message
    /// without re-introducing magic-string comparisons in the view.
    var isStatusIdle: Bool {
        statusText == SHAppViewModel.idleStatus
    }
    /// Single source of truth for the "nothing to report" status. Bound
    /// by Czech locale today; when full i18n lands the view-model
    /// will re-localize this from a String Catalog key.
    static let idleStatus: String = "Připraveno"
    var isRunning: Bool = false
    /// Outcome of the most recent run, used to show a persistent badge
    /// ("Hotovo" / "Přerušeno" / "Selhalo") until the user explicitly acknowledges
    /// by clicking it. `nil` means either no run happened yet, or the last badge
    /// was already dismissed.
    var lastCompletion: SHRunCompletion?
    /// ID of the server for which verification last succeeded in this session. Used to
    /// style the "Ověřit server" button green only after a confirmed round-trip. Reset on
    /// server switch, edit, add, or remove.
    var verifiedServerID: UUID?
    /// Number of PDFs found in the configured input folder (recursive scan). Drives
    /// the "N PDF" chip under the input row so the user sees there is data to
    /// process before pressing Run. `nil` until first scan; refreshed on folder
    /// change. The chip distinguishes "0 found" (chip with 0) from "not scanned
    /// yet" (chip hidden) — they imply different next actions.
    var inputFolderPdfCount: Int?
    /// Total bytes of the PDFs counted by `inputFolderPdfCount`. Shown next to the
    /// chip as "N PDF · X MB" so the user gets a quick sense of batch size before
    /// kicking off a multi-minute run.
    var inputFolderPdfBytes: Int64?
    /// Live ticker of paths currently in flight inside the active pipeline phase
    /// (FAST/SEARCH extraction or preprocessing). Drives the granular sub-line in
    /// the Progress card. Mirrored onto `progressState.currentlyProcessing` so all
    /// phase-related state lives in one struct, but exposed here too for the
    /// view's `.onChange` subscriptions.
    private var inflightItems: Set<String> = []

    /// Last few non-empty prompts the user actually launched a run with.
    /// Persisted across launches so that the most common scenario (user
    /// iterates on a prompt, runs, edits, runs) keeps a recoverable trail
    /// even when SwiftUI's TextEditor undo stack is gone (cleared on
    /// app restart). Capped at `promptHistoryLimit`. Most recent first.
    var promptHistory: [String] = []
    static let promptHistoryLimit: Int = 8

    /// Recent paths picked / dropped into each folder slot. Keyed by the
    /// folder kind (`SHFolderKind`) and persisted so users can hop between
    /// 2-3 active projects without re-navigating Finder each time. Most
    /// recent first, deduped, capped at `recentFoldersLimit`.
    var recentFolders: [SHFolderKind: [String]] = [:]
    static let recentFoldersLimit: Int = 5

    /// Recently-touched `.spiceharvester.json` project files (both saved
    /// via Cmd+Shift+S and opened via Cmd+O). Drives the
    /// `File → Otevřít nedávné…` submenu so users don't have to
    /// re-navigate the open panel for their 5–8 most active projects.
    /// Most recent first, deduped, capped at `recentProjectsLimit`.
    var recentProjectURLs: [URL] = []
    static let recentProjectsLimit: Int = 8

    /// Security-scoped bookmarks for project file URLs, keyed by absolute
    /// path. Kept **separately** from `SHAppConfig.folderBookmarks`
    /// because that struct is intentionally wiped at launch (see README
    /// "Persistence" — provozní vstupy se resetují). Project bookmarks
    /// need to survive restart so `Otevřít nedávné` actually works — a
    /// path string alone gives us nothing in a sandboxed app after the
    /// session that issued the NSOpenPanel grant has ended.
    private var projectBookmarks: [String: Data] = [:]

    /// Result-summary fields produced by the most recent extraction run.
    /// Populated at the tail of `performExtraction` and broadcast via
    /// `SHIntentNotifications.runDidComplete` so an awaiting
    /// `RunSpiceHarvesterIntent` from Shortcuts.app can return a
    /// structured payload to the calling workflow.
    private var lastRunDocumentCount: Int = 0
    private var lastRunCSVPath: String = ""

    /// Snapshot of config fields that `applyIntentParameters` overrode
    /// for the current Shortcuts.app run. Restored in
    /// `broadcastRunDidComplete` so the user's GUI state isn't
    /// permanently mutated by a per-run override. nil when no
    /// override is active (most runs).
    private var intentOverrideRestore: (mode: SHExtractionMode, prompt: String, lastPromptName: String)?

    /// Is the currently selected server's last verification still valid?
    var isSelectedServerVerified: Bool {
        guard let id = verifiedServerID, let current = selectedServer else { return false }
        return id == current.id
    }

    /// Whether the most recent ambient health check succeeded. Defaults to
    /// true and only flips false after at least one ambient ping fails on
    /// a verified server. Drives a red tint on the run-row status pill so
    /// the user sees that LM Studio crashed mid-session before they click
    /// Run and wait through a full HTTP timeout.
    var isVerifiedServerReachable: Bool = true

    /// Invalidate the "verified" badge whenever the server's identity or credentials
    /// change (URL or API key edit, server switch, etc.).
    func invalidateServerVerification() {
        verifiedServerID = nil
        isVerifiedServerReachable = true
        stopServerHealthWatcher()
    }

    // MARK: – Can-run predicates
    //
    // These drive the enabled/disabled styling of action buttons in the UI.
    // A button is tinted blue when its predicate is true, otherwise it is disabled
    // (SwiftUI renders disabled bordered buttons in a neutral gray tone automatically).

    var hasInputFolder: Bool {
        !config.inputFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasOutputFolder: Bool {
        !config.outputFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasPromptFolder: Bool {
        !config.promptFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCacheFolder: Bool {
        !config.cacheFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAllInputFolders: Bool {
        hasInputFolder && hasOutputFolder && hasCacheFolder && hasPromptFolder
    }

    var hasInferenceModel: Bool {
        !config.selectedInferenceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasOCRModel: Bool {
        !config.selectedOCRModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasPrompt: Bool {
        !promptWithoutThinkingMarker(config.currentPrompt).isEmpty
    }

    var promptThinkingMode: SHPromptThinkingMode? {
        let firstMeaningfulLine = config.currentPrompt
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty }

        switch firstMeaningfulLine {
        case "/no_think", "nothinking", "no thinking", "no-thinking":
            return .noThinking
        case "/think", "thinking":
            return .thinking
        default:
            return nil
        }
    }

    var hasSelectedServer: Bool {
        guard let server = selectedServer else { return false }
        return !server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canVerifyServer: Bool { hasSelectedServer }

    var canLoadPrompts: Bool { hasPromptFolder }

    private var usesServerBackedOCR: Bool {
        config.ocrBackend == .openAIVision || config.ocrBackend == .appleVisionThenOpenAI
    }

    private var hasOCRPreprocessingRequirements: Bool {
        !usesServerBackedOCR || (hasSelectedServer && hasOCRModel)
    }

    var canRunPreprocessing: Bool {
        hasInputFolder && hasOCRPreprocessingRequirements
    }

    /// Extraction needs output, a selected server (its `baseURL` must be non-empty),
    /// an inference model, a non-empty prompt, and at least the input folder (so
    /// preprocessing can run if no cache is present yet). Missing any one of these
    /// would make `performExtraction` return `.notStarted` silently – the button
    /// must be disabled instead of letting the user click it and see nothing.
    var canRunExtraction: Bool {
        hasInputFolder
        && hasOutputFolder
        && hasInferenceModel
        && hasPrompt
        && hasSelectedServer
        && (!cachedDocuments.isEmpty || hasOCRPreprocessingRequirements)
    }

    var canRunAll: Bool { canRunExtraction && canRunPreprocessing }

    var canOpenOutput: Bool { hasOutputFolder }

    /// True when the project has at least one meaningful field set, so
    /// "Uložit projekt jako…" produces a non-empty snapshot. Empty
    /// project save = JSON with only empty strings, useless and confusing.
    var canSaveProject: Bool {
        hasInputFolder || hasOutputFolder || hasPrompt
    }

    var toolbarReadyText: String {
        if isRunning { return "Zpracovávám…" }
        if !hasAllInputFolders { return "Zadej cesty ke složkám" }
        if !hasModelParameters { return "Nastav parametry modelu" }
        if !hasPrompt { return "Zadej prompt nebo ho načti ze seznamu" }
        if canRunAll { return "Můžeš spustit" }
        return "Nastav parametry modelu"
    }

    /// Title shown in the window's title bar (and in each tab when
    /// macOS merges multiple SpiceHarvester windows into a tabbed
    /// window — primary + Cmd+Shift+N scratch windows). Picks a
    /// human-readable tag that identifies *what this window is
    /// working on* so the user can tell tabs apart at a glance
    /// instead of seeing four identical "SpiceHarvester" labels.
    ///
    /// Priority (most specific → most generic):
    ///   1. Input folder name (most meaningful — answers "which batch?")
    ///   2. Loaded prompt name (when no input is set yet)
    ///   3. "scratch" indicator for unconfigured scratch windows
    ///   4. Bare app name for the empty primary window
    ///
    /// Updates reactively because `config.inputFolder` /
    /// `config.lastLoadedPromptName` / `isRunning` are observable.
    var windowTitle: String {
        let base = "Spice Harvester"
        let inputName = (config.inputFolder as NSString).lastPathComponent
        let promptStem = (config.lastLoadedPromptName as NSString)
            .deletingPathExtension
        let tag: String
        if !inputName.isEmpty {
            tag = inputName
        } else if !promptStem.isEmpty {
            tag = promptStem
        } else if persistenceMode == .scratch {
            tag = "scratch"
        } else {
            return base
        }
        let scratchMark = persistenceMode == .scratch ? " · scratch" : ""
        return "\(base) — \(tag)\(scratchMark)"
    }

    /// Optional subtitle line shown under the window title (macOS
    /// title bar supports primary + secondary text). Composes:
    /// `{server name} · {mode} · {progress | last-result}`. Server
    /// name is the always-visible discriminator — when the user
    /// runs different LM Studio / MLX instances in different tabs,
    /// the title bar tells them at a glance which tab points
    /// where (and lets them pair tabs with distinct hardware to
    /// achieve real parallelism instead of queueing on one server).
    var windowSubtitle: String {
        var parts: [String] = []
        if let server = selectedServer {
            // Server.name when set; otherwise fall back to host portion
            // of the base URL so generic "Local LM Studio" entries
            // don't all read identically in the bar.
            let trimmed = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmed.isEmpty
                ? (URL(string: server.baseURL)?.host ?? server.baseURL)
                : trimmed
            parts.append(label)
        }
        if isRunning {
            let modeLabel = config.extractionMode.title
            if progressState.counters.foundPDFs > 0 {
                parts.append("\(modeLabel) · \(progressState.counters.completed) / \(progressState.counters.foundPDFs)")
            } else {
                parts.append("\(modeLabel) · běží")
            }
        } else if lastRunDocumentCount > 0 {
            parts.append("Hotovo · \(lastRunDocumentCount) dokumentů")
        }
        return parts.joined(separator: " · ")
    }

    private var hasModelParameters: Bool {
        hasSelectedServer && hasInferenceModel && hasOCRPreprocessingRequirements
    }

    /// Human-readable list of missing preconditions for `canRunExtraction` / `canRunAll`.
    /// Returns `nil` when the run can start. Used as the tooltip on the disabled
    /// action buttons so the user immediately sees *which* field needs filling –
    /// previously the grayed-out button gave no hint and the silent notStarted
    /// guard inside `performExtraction` just flashed a line in the status bar.
    var missingRequirementsHint: String? {
        var missing: [String] = []
        if !hasInputFolder     { missing.append("vstupní složka") }
        if !hasOutputFolder    { missing.append("výstupní složka") }
        if !hasSelectedServer  { missing.append("server (Base URL)") }
        if !hasInferenceModel  { missing.append("inference model") }
        if !hasPrompt          { missing.append("prompt") }
        if usesServerBackedOCR && !hasOCRModel { missing.append("OCR/VLM model") }
        guard !missing.isEmpty else { return nil }
        return "Chybí: \(missing.joined(separator: ", "))"
    }

    /// Tooltip text for the disabled Preprocessing button.
    var missingPreprocessingHint: String? {
        var missing: [String] = []
        if !hasInputFolder { missing.append("vstupní složka") }
        if usesServerBackedOCR && !hasSelectedServer { missing.append("server (Base URL)") }
        if usesServerBackedOCR && !hasOCRModel { missing.append("OCR/VLM model") }
        guard !missing.isEmpty else { return nil }
        return "Chybí: \(missing.joined(separator: ", "))"
    }

    // MARK: – Performance estimate

    /// Number of documents currently held in memory and ready for extraction.
    /// Drives the Benchmark card's total-duration estimate ("X min celkem").
    var pendingDocumentCount: Int { cachedDocuments.count }

    /// Estimated total duration for the next run, in milliseconds. Based on:
    /// `lastRunAvgDocumentMs × max(pendingDocumentCount, inputFolderPdfCount)`.
    /// Returns `nil` when no history exists yet.
    var estimatedRunDurationMs: Double? {
        guard config.lastRunAvgDocumentMs > 0 else { return nil }
        let count = pendingDocumentCount
        guard count > 0 else { return nil }
        return config.lastRunAvgDocumentMs * Double(count)
    }

    /// Per-document baseline (ms) from the most recent successful run. Nil when
    /// the user hasn't completed a run yet.
    var estimatedPerDocumentMs: Double? {
        config.lastRunAvgDocumentMs > 0 ? config.lastRunAvgDocumentMs : nil
    }

    // MARK: – Parameter / prompt conflict detection

    /// Debounced snapshot of `parameterConflicts` shown in the UI. Direct
    /// observation of `parameterConflicts` would re-render the banner on
    /// every keystroke (the analyzer scans the prompt for keywords and
    /// changes its verdict mid-word: "consol" → no match, "consolidate"
    /// → match), which produced visible flicker. The view reads this
    /// instead and `scheduleConflictUpdate()` syncs it 400 ms after the
    /// last change.
    var displayedConflicts: [SHParameterConflict] = []
    private var conflictDebounceTask: Task<Void, Never>?
    /// Set of conflict identifiers the user explicitly dismissed in this
    /// session. Filtered out of `displayedConflicts` before assignment.
    /// Per-session only (no UserDefaults) — when the underlying state
    /// changes the dismissal naturally resets via `dismissedConflictIDs`
    /// being keyed off conflict identity, not config snapshot.
    private var dismissedConflictIDs: Set<String> = []

    /// Schedules an update of `displayedConflicts` to the current value of
    /// `parameterConflicts` after a debounce window. Called from view-model
    /// setters that affect conflict detection (prompt edits, mode picker,
    /// embedding model picker). Repeated calls cancel the previous wait
    /// and start a new one — classic trailing-edge debounce.
    func scheduleConflictUpdate(after delayMs: Int = 400) {
        conflictDebounceTask?.cancel()
        let snapshotDelay = UInt64(max(0, delayMs)) * 1_000_000
        conflictDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: snapshotDelay)
            guard !Task.isCancelled, let self else { return }
            self.displayedConflicts = self.parameterConflicts.filter { conflict in
                !self.dismissedConflictIDs.contains(conflict.dismissID)
            }
        }
    }

    /// Dismiss an informational conflict banner for this session. Used
    /// for the consolidate-ignores-concurrency notice which has no
    /// corrective action — the user has read it, doesn't need to be
    /// reminded every keystroke. Re-appears on next launch.
    ///
    /// Single source of truth: only `dismissedConflictIDs` is the
    /// authority. `displayedConflicts` is a debounced cache that
    /// `scheduleConflictUpdate(after: 0)` immediately rebuilds —
    /// previously this method also imperatively mutated
    /// `displayedConflicts`, which created a dual-source-of-truth bug
    /// (out-of-band callers writing to `displayedConflicts` would lose
    /// the dismissal until the next debounced refresh).
    func dismissConflict(_ conflict: SHParameterConflict) {
        dismissedConflictIDs.insert(conflict.dismissID)
        scheduleConflictUpdate(after: 0)
    }

    /// All currently-active conflicts between `config` and `config.currentPrompt`.
    /// Rendered as banners in the UI. Recomputed via `@Observable` tracking whenever
    /// either the prompt text or the extraction mode changes.
    var parameterConflicts: [SHParameterConflict] {
        var result: [SHParameterConflict] = []

        if let suggestion = SHPromptAnalyzer.suggestedMode(for: config.currentPrompt),
           suggestion.mode != config.extractionMode {
            result.append(.modeMismatch(
                current: config.extractionMode,
                suggested: suggestion.mode,
                reason: suggestion.reason
            ))
        }

        let embeddingModelSelected = !config.selectedEmbeddingModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if config.extractionMode == .search && !embeddingModelSelected {
            result.append(.searchModeWithoutEmbeddingModel)
        }

        if config.extractionMode == .consolidate {
            result.append(.consolidateIgnoresConcurrency)
        }

        return result
    }

    // MARK: – Onboarding checklist

    /// Steps shown in the onboarding banner. Banner is hidden in the view layer
    /// once `isSetupComplete` flips true, but this list always exposes all 4 steps
    /// so the row count never changes (avoids layout jumps as steps are checked).
    var setupSteps: [SHSetupStep] {
        [
            SHSetupStep(
                id: "input",
                title: "Vyber vstupní složku",
                hint: "Sem dej PDF dokumenty, které chceš zpracovat.",
                isDone: hasInputFolder
            ),
            SHSetupStep(
                id: "output",
                title: "Vyber výstupní složku",
                hint: "Sem aplikace zapíše JSON / CSV / TXT a log.",
                isDone: hasOutputFolder
            ),
            SHSetupStep(
                id: "server",
                title: "Server a inference model",
                hint: "Spusť LM Studio nebo MLX, klikni Ověřit a vyber model.",
                isDone: hasSelectedServer && hasInferenceModel
            ),
            SHSetupStep(
                id: "prompt",
                title: "Zadej nebo načti prompt",
                hint: "Prompt definuje schéma výstupu a režim extrakce.",
                isDone: hasPrompt
            ),
        ]
    }

    /// True when every step in `setupSteps` is done. View hides the onboarding
    /// banner the moment this flips. Computed (not stored) so it never goes out
    /// of sync with the underlying predicates.
    var isSetupComplete: Bool {
        setupSteps.allSatisfy(\.isDone)
    }

    // MARK: – Input folder stats

    /// Re-scans the input folder for PDFs and updates `inputFolderPdfCount` /
    /// `inputFolderPdfBytes`. The scan runs on a detached background task —
    /// folders with thousands of files would otherwise block the main thread
    /// long enough to drop frames during typing / window resize. Subsequent
    /// calls cancel the in-flight scan so the user always sees stats for the
    /// **current** folder, never a stale earlier scan that finished late.
    func refreshInputFolderStats() {
        let trimmed = config.inputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        // Always cancel any pending scan first. Newer folder selection wins.
        inputFolderScanTask?.cancel()
        inputFolderScanTask = nil

        guard !trimmed.isEmpty else {
            inputFolderPdfCount = nil
            inputFolderPdfBytes = nil
            return
        }

        // Snapshot scoped URL on the main actor (security-scoped resolution
        // touches MainActor-isolated config), then hand the URL to a
        // background task for the actual filesystem walk.
        guard let url = resolveScopedURL(for: trimmed) else {
            inputFolderPdfCount = nil
            inputFolderPdfBytes = nil
            return
        }

        inputFolderScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Hold scoped access only inside the detached task — main actor
            // doesn't need to wait for the scan to finish before returning.
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }

            let scanner = SHFileScanService()
            let urls = scanner.recursivePDFs(in: url)

            // Cooperative cancellation between scan and size summation.
            if Task.isCancelled { return }

            var bytes: Int64 = 0
            for u in urls {
                if Task.isCancelled { return }
                if let size = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    bytes += Int64(size)
                }
            }
            let count = urls.count
            let totalBytes = bytes

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.inputFolderPdfCount = count
                self.inputFolderPdfBytes = totalBytes
            }
        }
    }

    /// Human-readable label for the chip under the input folder row. Returns nil
    /// when no scan has run yet — the view hides the chip in that case.
    var inputFolderChipLabel: String? {
        guard let count = inputFolderPdfCount else { return nil }
        if count == 0 {
            return "Žádné PDF"
        }
        if let bytes = inputFolderPdfBytes, bytes > 0 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return "\(count) PDF · \(formatter.string(fromByteCount: bytes))"
        }
        return "\(count) PDF"
    }

    // MARK: – Item lifecycle (granular progress)

    /// Called from the pipeline when a single document/batch starts running.
    /// Adds the item to `inflightItems` and mirrors the set onto
    /// `progressState.currentlyProcessing` (sorted, capped at 6) so the progress
    /// card has a deterministic, bounded list to render.
    func itemStarted(_ name: String) {
        inflightItems.insert(name)
        progressState.currentlyProcessing = Array(inflightItems.sorted().prefix(6))
        progressState.lastProgressAt = Date()
    }

    /// Called from the pipeline when a single document/batch finishes (success,
    /// failure, or cancellation — all three count as "no longer in flight"). The
    /// last finished name is kept so the user always sees forward motion, even
    /// in the brief gaps between throttle pauses.
    func itemFinished(_ name: String) {
        inflightItems.remove(name)
        progressState.currentlyProcessing = Array(inflightItems.sorted().prefix(6))
        progressState.lastFinishedItem = name
        progressState.lastProgressAt = Date()
    }

    /// Resets the granular-progress book-keeping at the start of each run.
    func resetItemTracking() {
        inflightItems.removeAll()
        progressState.currentlyProcessing = []
        progressState.lastFinishedItem = nil
    }

    /// One-click apply for a conflict. Mirrors the button in the banner.
    func apply(_ conflict: SHParameterConflict) {
        switch conflict {
        case .modeMismatch(_, let suggested, _):
            config.extractionMode = suggested
            persistAll()
        case .searchModeWithoutEmbeddingModel:
            config.extractionMode = .fast
            persistAll()
        case .consolidateIgnoresConcurrency:
            break // informational only
        }
    }

    private let configStore = SHConfigStore()
    private let serverStore = SHServerRegistryStore()
    /// OpenAI-compatible local inference client. Recreated whenever `config.requestTimeoutSeconds`
    /// changes so the new timeout takes effect immediately (URLSessionConfiguration
    /// is captured at session creation and can't be mutated post-hoc).
    private var lmClient = SHOpenAICompatibleClient()
    private let promptService = SHPromptLibraryService()
    private let exportService = SHExportService()
    private let benchmarkService = SHBenchmarkService()

    private var cacheManager: SHCacheManager?
    private var inferenceCache: SHInferenceCache?
    private var embeddingCache: SHEmbeddingCache?
    private var logger: SHProcessingLogger?
    /// Output folder path the current `logger` was opened against. Used to detect user
    /// changing the output folder so we can reopen the log file in the new location.
    private var loggerOutputPath: String = ""
    private var cachedDocuments: [SHCachedDocument] = []
    /// Input folder path used to populate `cachedDocuments`. Used to invalidate the
    /// cache when the user switches to a different input folder.
    private var cachedDocumentsInputPath: String = ""
    /// Currently running task, if any. Used to prevent double-runs and to support
    /// user-initiated cancellation.
    private var currentTask: Task<SHRunOutcome, Never>?
    private var embeddingValidationTask: Task<Void, Never>?
    /// Detached task scanning the input folder for PDFs. Held so that
    /// successive `refreshInputFolderStats` calls can cancel the previous
    /// scan — switching folders rapidly would otherwise let an old scan
    /// finish and overwrite stats for the new folder.
    private var inputFolderScanTask: Task<Void, Never>?
    /// Background ping loop that re-checks `/v1/models` every 30 s while
    /// a server is verified. Cancelled when the user invalidates the
    /// server (URL edit, server switch) — `invalidateServerVerification`
    /// stops it and `verifyServer` restarts it on success.
    private var serverHealthTask: Task<Void, Never>?
    /// Tracks the in-flight manual recheck triggered by Pipeline →
    /// "Znovu ověřit zdraví serveru". Cancelled before a new recheck
    /// starts so rapid clicks don't spawn N parallel pings; the LM
    /// Studio server typically replies in <100 ms so the practical
    /// race is small, but the gate avoids redundant retry chains
    /// under flaky network.
    private var manualHealthCheckTask: Task<Void, Never>?
    /// True for the brief window where a task is about to start – guards against
    /// back-to-back clicks racing past the `isRunning` flag.
    private var runEntered: Bool = false
    /// Parent directory of the folder picked most recently in this session. Used
    /// as the starting location for subsequent folder pickers so project siblings
    /// (Vstup / Výstup / Cache / Prompty) are one click away instead of navigating
    /// from home every time. Session-only; not persisted.
    private var lastPickedFolderParent: URL?

    /// How aggressively this view-model persists changes back to
    /// UserDefaults. Primary windows use `.persistent` (the default,
    /// behavior pre-multi-window), scratch windows opened via Cmd+Shift+N
    /// use `.scratch` so two windows don't fight over the same UserDefaults
    /// key on every keystroke.
    enum PersistenceMode {
        case persistent
        case scratch
    }
    private let persistenceMode: PersistenceMode

    init(persistenceMode: PersistenceMode = .persistent) {
        self.persistenceMode = persistenceMode
        self.servers = serverStore.loadServers()

        // Every launch starts with a clean slate. Only the local AI server registry
        // and a handful of non-destructive behavior preferences survive across sessions.
        // Folders, folder bookmarks, prompt text, the last loaded prompt name, and the
        // model selections are all cleared so the user always begins from an empty state.
        let persisted = configStore.load()
        var freshConfig = SHAppConfig()
        freshConfig.extractionMode = persisted.extractionMode
        freshConfig.maxConcurrentInference = persisted.maxConcurrentInference
        freshConfig.maxConcurrentPDFWorkers = persisted.maxConcurrentPDFWorkers
        freshConfig.throttleDelayMs = persisted.throttleDelayMs
        freshConfig.modelContextTokens = persisted.modelContextTokens
        freshConfig.requestTimeoutSeconds = persisted.requestTimeoutSeconds
        freshConfig.selectedServerID = persisted.selectedServerID
        freshConfig.ocrBackend = persisted.ocrBackend
        freshConfig.lastRunAvgDocumentMs = persisted.lastRunAvgDocumentMs
        freshConfig.lastRunAvgPageMs = persisted.lastRunAvgPageMs
        self.config = freshConfig

        // Heal a stale `selectedServerID` that no longer maps to an existing server
        // (e.g. server was removed in a previous session but the ID persisted).
        let hasMatchingServer = config.selectedServerID.flatMap { id in
            servers.first(where: { $0.id == id })
        } != nil
        if !hasMatchingServer {
            config.selectedServerID = servers.first?.id
        }

        // Persist cleared state right away so stale paths/bookmarks don't linger in
        // UserDefaults between launches. Scratch windows skip — they have
        // no business overwriting the primary window's persisted slot.
        if persistenceMode == .persistent {
            configStore.save(config)
        }

        // Build the OpenAI-compatible client with the persisted timeout preference (so the
        // user's last chosen value is in effect immediately, not only after they
        // first touch the stepper).
        rebuildLMClient()

        // Notification authorization request lives in SHAppDelegate so it
        // fires once per process, not once per view-model (every scratch
        // window would re-trigger setNotificationCategories otherwise).

        // Restore prompt history (deduped string array). Limited to N entries
        // per `promptHistoryLimit`, anything beyond is silently truncated.
        if let saved = UserDefaults.standard.array(forKey: Self.promptHistoryKey) as? [String] {
            self.promptHistory = Array(saved.prefix(Self.promptHistoryLimit))
        }

        // Seed displayedConflicts so the banner reflects the initial state
        // even before the user touches anything (search-mode-without-embedding
        // matters from the moment the app opens with that config).
        self.displayedConflicts = self.parameterConflicts

        // Restore recent folders for each slot. Stored per-kind so a power
        // user with separate prompt / output projects keeps both lists.
        for kind in SHFolderKind.allCases {
            let key = Self.recentFolderKey(for: kind)
            if let saved = UserDefaults.standard.array(forKey: key) as? [String] {
                self.recentFolders[kind] = Array(saved.prefix(Self.recentFoldersLimit))
            }
        }

        // Restore recent project file URLs + their security-scoped
        // bookmarks from UserDefaults. Centralised in
        // `reloadRecentProjectsFromDefaults` so the cross-window
        // observer below can re-trigger the same load when a peer
        // window posts `recentProjectsDidChange`.
        reloadRecentProjectsFromDefaults()

        // Flush any pending debounced persist when the app is about to terminate.
        // Prevents data loss when the user is mid-edit (300 ms window) and
        // force-quits / crashes / hits the power button.
        // The notification's user-info closure isn't main-actor-isolated, so we
        // hop back via `MainActor.run` before touching `persistAll()`.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.persistAll()
            }
        }

        // AppIntents bridge: the Shortcuts app / Siri / Spotlight invoke our
        // intents without holding a reference to this view-model. The intents
        // post these notifications and we react here. See `SHAppIntents.swift`
        // for the producing side.
        //
        // CRITICAL: only the .persistent (primary) view-model registers the
        // observer. Without this gate, every scratch window's view-model
        // would also react to the AppIntent post and fire `runAll()` in
        // parallel — N copies of the pipeline competing for the same LM
        // Studio server, racing to write the same output folder.
        if #available(macOS 13.0, *), persistenceMode == .persistent {
            // Only `openOutput` remains routed via NotificationCenter:
            // `SHAppDelegate.userNotificationCenter(_:didReceive:...)`
            // (the UN action button on completion banners) has no
            // direct vm reference, so the notification bridge stays.
            // `runAll` / `applyParameters` / `runDidComplete` moved
            // to direct method calls via `SHAppViewModel.runFromIntent`
            // — removed the NotificationCenter dance that had two
            // races: (1) primary + scratch claiming the same broadcast,
            // (2) the intent observer matching the wrong vm's reply.
            NotificationCenter.default.addObserver(
                forName: SHIntentNotifications.openOutput,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.openOutput()
                }
            }
        }

        // Cross-window recents sync. When another view-model (a peer
        // scratch window, or the primary in the inverse direction)
        // writes to the shared `SHRecentProjects` / `SHProjectBookmarks`
        // UserDefaults keys, it posts `recentProjectsDidChange` so we
        // can refresh our in-memory copy and the `File → Otevřít
        // nedávné…` menu reflects the new list without an app restart.
        // We skip notifications we posted ourselves (identity check on
        // `object`) — UserDefaults already holds the value we just
        // mutated, so re-reading is wasted work.
        //
        // `MainActor.assumeIsolated` (not `Task { @MainActor in }`)
        // because `queue: .main` already pins the block to the main
        // thread / main actor. Avoiding the Task hop keeps the refresh
        // synchronous with the post — important for tests and for
        // tight save→display cycles where a queued Task could lag
        // behind a UI redraw.
        NotificationCenter.default.addObserver(
            forName: Self.recentProjectsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let sender = notification.object as AnyObject?, sender === self { return }
                self.reloadRecentProjectsFromDefaults()
            }
        }

        // Register in the process-wide live registry so a
        // `RunSpiceHarvesterIntent` (Shortcuts.app) can locate this
        // vm by its input-folder name and call `runAll` directly.
        // `NSHashTable.weakObjects()` auto-removes the entry on
        // dealloc — no manual unregister in deinit. Must happen
        // AFTER all stored properties are initialized; `Self.liveRegistry.add(self)`
        // passes `self` which Swift won't allow before init completes
        // its property assignments.
        Self.liveRegistry.add(self)
    }

    var selectedServerIndex: Int {
        get {
            guard let id = config.selectedServerID,
                  let index = servers.firstIndex(where: { $0.id == id }) else {
                // Self-heal: stored ID points to a server that no longer exists.
                // Align config with reality (first available server or nil) so the
                // picker, `selectedServer`, and `config.selectedServerID` all agree.
                return 0
            }
            return index
        }
        set {
            guard servers.indices.contains(newValue) else { return }
            config.selectedServerID = servers[newValue].id
            clearModelSelectionForServerChange()
            invalidateServerVerification()
            persistAll()
        }
    }

    var selectedServer: SHServerConfig? {
        guard servers.indices.contains(selectedServerIndex) else { return nil }
        return servers[selectedServerIndex]
    }

    func addServer() {
        servers.append(.init(name: "Server \(servers.count + 1)", baseURL: "http://localhost:1234/v1", apiKey: ""))
        config.selectedServerID = servers.last?.id
        clearModelSelectionForServerChange()
        invalidateServerVerification()
        persistAll()
    }

    func addMLXServer() {
        servers.append(.init(name: "Local MLX", baseURL: "http://localhost:8000/v1", apiKey: ""))
        config.selectedServerID = servers.last?.id
        clearModelSelectionForServerChange()
        invalidateServerVerification()
        persistAll()
    }

    func removeSelectedServer() {
        guard !servers.isEmpty else { return }
        servers.remove(at: selectedServerIndex)
        config.selectedServerID = servers.first?.id
        clearModelSelectionForServerChange()
        if servers.isEmpty {
            addServer()
        }
        invalidateServerVerification()
        persistAll()
    }

    private func clearModelSelectionForServerChange() {
        embeddingValidationTask?.cancel()
        embeddingValidationTask = nil
        availableModels = []
        config.selectedInferenceModel = ""
        config.selectedEmbeddingModel = ""
        config.selectedRerankerModel = ""
        config.selectedOCRModel = ""
    }

    func serverConnectionDetailsChanged() {
        clearModelSelectionForServerChange()
        invalidateServerVerification()
        persistAllDebounced()
    }

    func setInferenceModel(_ model: String) {
        config.selectedInferenceModel = model
        persistAllDebounced()
    }

    func setEmbeddingModel(_ model: String) {
        config.selectedEmbeddingModel = model
        persistAllDebounced()
        validateSelectedEmbeddingModel()
        scheduleConflictUpdate(after: 0)
    }

    func setRerankerModel(_ model: String) {
        config.selectedRerankerModel = model
        persistAllDebounced()
    }

    func setOCRModel(_ model: String) {
        config.selectedOCRModel = model
        invalidateCachedDocumentsForPreprocessingChange()
        persistAllDebounced()
    }

    func setOCRBackend(_ backend: SHOCRBackend) {
        config.ocrBackend = backend
        invalidateCachedDocumentsForPreprocessingChange()
        persistAll()
    }

    private func invalidateCachedDocumentsForPreprocessingChange() {
        if !cachedDocuments.isEmpty {
            cachedDocuments.removeAll()
            cachedDocumentsInputPath = ""
            progressState.counters = SHPipelineCounters()
            statusText = "Nastavení OCR se změnilo – cache předzpracování v paměti byla zahozena"
        }
    }

    private func validateSelectedEmbeddingModel() {
        embeddingValidationTask?.cancel()
        embeddingValidationTask = nil

        let model = config.selectedEmbeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let server = selectedServer else { return }

        let serverID = server.id
        let client = lmClient
        statusText = "Ověřuji embedding endpoint"

        embeddingValidationTask = Task { [weak self] in
            let supported = await client.supportsEmbeddings(server: server, model: model)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.selectedServer?.id == serverID,
                      self.config.selectedEmbeddingModel == model else {
                    return
                }
                self.statusText = supported
                    ? "Embedding endpoint ověřen"
                    : "Embedding endpoint nedostupný – SEARCH použije fallback bez RAG"
            }
        }
    }

    func persistAll() {
        persistDebounceTask?.cancel()
        persistDebounceTask = nil
        // Scratch windows skip the global config write so secondary
        // windows don't overwrite the primary's saved state. Server
        // registry changes still go through — a new server added in
        // a scratch window stays available everywhere, which matches
        // the user's mental model ("servers are global"). To save a
        // scratch window's config the user uses Uložit projekt jako…
        if persistenceMode == .persistent {
            configStore.save(config)
        }
        serverStore.saveServers(servers)
    }

    /// Debounced variant for keystroke-driven bindings (prompt text, server URL).
    /// Writes to UserDefaults only after the user pauses for `delayMs` ms, so long
    /// edits don't hammer disk on every character.
    private var persistDebounceTask: Task<Void, Never>?
    func persistAllDebounced(delayMs: Int = 300) {
        persistDebounceTask?.cancel()
        // Scratch windows: skip debounced writes too. Same reasoning.
        guard persistenceMode == .persistent else { return }
        persistDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.configStore.save(self?.config ?? SHAppConfig())
            self?.serverStore.saveServers(self?.servers ?? [])
        }
    }

    func chooseInputFolder() {
        pickFolder(into: \.inputFolder, kind: .input) {
            self.invalidateCachedDocumentsIfInputChanged()
            self.refreshInputFolderStats()
        }
    }
    func chooseOutputFolder() { pickFolder(into: \.outputFolder, kind: .output) }
    func chooseCacheFolder() { pickFolder(into: \.cacheFolder, kind: .cache) }
    func choosePromptFolder() { pickFolder(into: \.promptFolder, kind: .prompt) }

    /// Opens the folder picker and, on success, writes the chosen path into
    /// `config[keyPath:]`, stores its security-scoped bookmark, records
    /// the path in the per-kind Recents store, and persists. `onChange`
    /// fires after the write, for side effects like cache invalidation.
    private func pickFolder(into keyPath: WritableKeyPath<SHAppConfig, String>,
                            kind: SHFolderKind,
                            onChange: (() -> Void)? = nil) {
        let currentValue = config[keyPath: keyPath]
        guard let url = chooseFolder(relativeTo: currentValue) else { return }
        config[keyPath: keyPath] = url.path
        storeBookmark(for: url)
        rememberRecentFolder(url.path, kind: kind)
        persistAll()
        onChange?()
    }

    /// Call this when the input folder path changes (via picker or direct text edit)
    /// to drop stale preprocessing results that came from a different folder.
    func invalidateCachedDocumentsIfInputChanged() {
        let current = config.inputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cachedDocuments.isEmpty && current != cachedDocumentsInputPath {
            cachedDocuments.removeAll()
            cachedDocumentsInputPath = ""
            progressState.counters = SHPipelineCounters()
            statusText = "Vstupní složka se změnila – cache v paměti byla zahozena"
        }
        // Drop any chip data tied to the old folder; the view triggers a fresh
        // scan via `.onChange(of: inputFolder)`.
        inputFolderPdfCount = nil
        inputFolderPdfBytes = nil
    }

    /// Refreshes the list of `.md` files available in the configured prompt folder.
    /// Does not load any file – the user picks one from the list afterwards.
    func reloadPromptFiles() {
        let trimmed = config.promptFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            availablePromptFiles = []
            selectedPromptFile = nil
            statusText = "Složka promptů není vybraná – nejdříve ji vyber přes 'Vybrat'"
            return
        }

        do {
            let result: (files: [URL], folderName: String)? = try withScopedAccess(to: trimmed) { url in
                let files = try promptService.listFiles(in: url)
                return (files, url.lastPathComponent)
            }
            guard let result else {
                availablePromptFiles = []
                selectedPromptFile = nil
                statusText = "Nelze otevřít složku promptů: \(trimmed)"
                return
            }
            availablePromptFiles = result.files
            if result.files.isEmpty {
                selectedPromptFile = nil
                statusText = "Ve složce \(result.folderName) nejsou žádné .md soubory"
            } else {
                // Preserve current selection if the previously loaded file still exists.
                if !config.lastLoadedPromptName.isEmpty,
                   let match = result.files.first(where: { $0.lastPathComponent == config.lastLoadedPromptName }) {
                    selectedPromptFile = match
                } else {
                    selectedPromptFile = nil
                }
                statusText = "Nalezeno \(result.files.count) promptů v \(result.folderName)"
            }
        } catch {
            availablePromptFiles = []
            selectedPromptFile = nil
            statusText = "Chyba při listování složky: \(error.localizedDescription)"
        }
    }

    /// Loads the content of the given `.md` file into `config.currentPrompt`.
    func loadPromptFile(_ fileURL: URL) {
        do {
            let loaded: String? = try withScopedAccess(to: config.promptFolder) { _ in
                try promptService.loadContent(of: fileURL)
            }
            guard let loaded else {
                statusText = "Nelze otevřít složku promptů"
                return
            }
            config.currentPrompt = loaded
            config.lastLoadedPromptName = fileURL.lastPathComponent
            persistAll()
            statusText = "Načten prompt: \(fileURL.lastPathComponent)"
        } catch {
            statusText = "Nelze načíst prompt: \(error.localizedDescription)"
        }
    }

    func clearPrompt() {
        config.currentPrompt = ""
        config.lastLoadedPromptName = ""
        selectedPromptFile = nil
        persistAll()
    }

    func applyPromptThinkingMode(_ mode: SHPromptThinkingMode) {
        let marker: String
        let statusMode: String
        switch mode {
        case .noThinking:
            marker = "/no_think"
            statusMode = "nothinking"
        case .thinking:
            marker = "/think"
            statusMode = "thinking"
        }

        let cleaned = promptWithoutThinkingMarker(config.currentPrompt)
        config.currentPrompt = cleaned.isEmpty ? marker : "\(marker)\n\(cleaned)"
        statusText = "Prompt přepnut na \(statusMode)"
        persistAllDebounced()
    }

    private func promptWithoutThinkingMarker(_ prompt: String) -> String {
        var lines = prompt.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        if let first = lines.first {
            let normalized = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["/no_think", "/think", "nothinking", "thinking", "no thinking", "no-thinking"].contains(normalized) {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func verifyServer() async {
        guard let server = selectedServer else {
            statusText = "Není vybraný server"
            return
        }

        do {
            try await lmClient.verifyServer(server)
            let models = try await lmClient.fetchModels(server)
            availableModels = models
            if config.selectedInferenceModel.isEmpty || !models.contains(config.selectedInferenceModel) {
                config.selectedInferenceModel = models.first ?? ""
            }
            if !config.selectedEmbeddingModel.isEmpty && !models.contains(config.selectedEmbeddingModel) {
                config.selectedEmbeddingModel = ""
            }
            if !config.selectedRerankerModel.isEmpty && !models.contains(config.selectedRerankerModel) {
                config.selectedRerankerModel = ""
            }
            if !config.selectedOCRModel.isEmpty && !models.contains(config.selectedOCRModel) {
                config.selectedOCRModel = ""
            }

            // Best-effort: LM Studio exposes per-model context length via its native
            // /api/v0/models endpoint. If we can get it, auto-populate
            // `config.modelContextTokens` so CONSOLIDATE pre-flight uses the real
            // limit instead of a guess. Silent degrade for MLX and other OpenAI-
            // compatible servers that do not expose the LM Studio native endpoint.
            var contextSuffix = " · kontext ručně"
            if let loaded = try? await lmClient.fetchLoadedModels(server),
               let detected = pickLoadedModel(loaded, preferred: config.selectedInferenceModel)?.effectiveContextLength {
                config.modelContextTokens = detected
                contextSuffix = " · kontext \(formatContextTokens(detected))"
            }

            verifiedServerID = server.id
            isVerifiedServerReachable = true
            persistAll()
            statusText = "Server dostupný · modely: \(models.count)\(contextSuffix)"
            validateSelectedEmbeddingModel()
            startServerHealthWatcher()
        } catch {
            if verifiedServerID == server.id {
                verifiedServerID = nil
            }
            isVerifiedServerReachable = true
            stopServerHealthWatcher()
            statusText = "Ověření selhalo: \(error.localizedDescription)"
        }
    }

    /// Starts (or restarts) a background loop that pings `/v1/models`
    /// every 30 s while a server is verified. The first failure flips
    /// `isVerifiedServerReachable` to `false`, the run-row pill goes
    /// red, and the user finds out *before* they click Run and burn
    /// 30 s on a doomed HTTP timeout. Subsequent successes restore the
    /// flag silently.
    private func startServerHealthWatcher() {
        stopServerHealthWatcher()
        let serverID = verifiedServerID
        serverHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                // Only ping while the server we started for is still
                // the verified one. Server switch / invalidation cancels
                // this task in `invalidateServerVerification`, but a
                // race-window check makes the loop robust.
                guard self.verifiedServerID == serverID,
                      let server = self.selectedServer else { return }
                do {
                    _ = try await self.lmClient.fetchModels(server)
                    if !Task.isCancelled, self.verifiedServerID == serverID {
                        self.isVerifiedServerReachable = true
                    }
                } catch {
                    if !Task.isCancelled, self.verifiedServerID == serverID {
                        self.isVerifiedServerReachable = false
                    }
                }
            }
        }
    }

    private func stopServerHealthWatcher() {
        serverHealthTask?.cancel()
        serverHealthTask = nil
    }

    /// Pick the most relevant loaded model from LM Studio's response:
    /// 1. Exact match on the currently-selected inference model.
    /// 2. Any model in "loaded" state.
    /// 3. First in the list.
    private func pickLoadedModel(_ models: [SHLMStudioLoadedModel],
                                 preferred: String) -> SHLMStudioLoadedModel? {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let match = models.first(where: { $0.id == trimmed }) {
            return match
        }
        if let anyLoaded = models.first(where: { $0.state?.lowercased() == "loaded" }) {
            return anyLoaded
        }
        return models.first
    }

    /// Recreate the OpenAI-compatible client so a changed `requestTimeoutSeconds` is
    /// applied. Called on init and whenever the user moves the Timeout stepper.
    func rebuildLMClient() {
        lmClient = SHOpenAICompatibleClient(requestTimeoutSeconds: config.requestTimeoutSeconds)
    }

    /// Format context like "32k" / "128k" / "1M" for compact status-bar display.
    private func formatContextTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return "\(tokens / 1_000_000)M tok." }
        if tokens >= 1024 { return "\(tokens / 1024)k tok." }
        return "\(tokens) tok."
    }

    /// Best-effort refresh of `config.modelContextTokens` from LM Studio's native
    /// `/api/v0/models` endpoint when the upcoming CONSOLIDATE batch looks like
    /// it might be close to or over the cached context. Catches the user-reloads-
    /// model-with-different-context scenario without pestering them with another
    /// "Ověřit server" prompt. Silent on failure (keeps the existing config value).
    private func refreshModelContextIfRisky(server: SHServerConfig) async {
        // Roughly estimate input size of the upcoming batch. Same heuristic as
        // SHExtractionPipeline (3 chars/token for Czech medical text).
        let totalChars = cachedDocuments.reduce(0) { $0 + $1.cleanedText.count }
        let estimatedTokens = Int(ceil(Double(totalChars) / 3.0))
        // Trigger refresh only when we're in the same order of magnitude as the
        // current limit (avoids a network hop for every small CONSOLIDATE batch).
        guard estimatedTokens > Int(Double(config.modelContextTokens) * 0.5) else { return }

        guard let loaded = try? await lmClient.fetchLoadedModels(server) else { return }
        let target = pickLoadedModel(loaded, preferred: config.selectedInferenceModel)
        guard let detected = target?.effectiveContextLength else { return }
        if detected != config.modelContextTokens {
            config.modelContextTokens = detected
            persistAll()
            statusText = "Aktualizováno – kontext modelu \(formatContextTokens(detected))"
        }
    }

    /// Persist the current benchmark's per-document / per-page averages so the
    /// Benchmark card can show a pre-flight estimate for the next run. Only
    /// updates when we actually have positive numbers (avoids clobbering a
    /// valid baseline with zeros from a no-op run).
    private func updateBaselineFromBenchmark() {
        if benchmark.avgPerDocumentMs > 0 {
            config.lastRunAvgDocumentMs = benchmark.avgPerDocumentMs
        }
        if benchmark.avgPerPageMs > 0 {
            config.lastRunAvgPageMs = benchmark.avgPerPageMs
        }
        persistAll()
    }

    // MARK: – Run orchestration
    //
    // Public `runXxx()` methods each:
    //   1. Return early if another run is in flight (double-run guard).
    //   2. Store a `Task` handle in `currentTask` so the UI can cancel it.
    //   3. Call the internal `performXxx()` which does the actual work without
    //      touching `isRunning`, avoiding the race where the flag flipped between
    //      phases of a multi-stage run like "Spustit".

    func runPreprocessing() async {
        await executeRun { await self.performPreprocessing() }
    }

    /// Pushes the current prompt onto `promptHistory` (most recent first,
    /// deduplicated, capped). Called at run start — only prompts the user
    /// actually committed to running are worth remembering, draft text is
    /// not persisted here.
    func recordPromptInHistory() {
        let trimmed = config.currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        promptHistory.removeAll { $0 == trimmed }
        promptHistory.insert(trimmed, at: 0)
        if promptHistory.count > Self.promptHistoryLimit {
            promptHistory.removeLast(promptHistory.count - Self.promptHistoryLimit)
        }
        // Scratch windows: keep history in-memory for the run (so
        // Cmd+Shift+Z / Historie menu work this session) but don't write
        // back. Otherwise an experimental scratch run pollutes the
        // primary window's persistent prompt history.
        guard persistenceMode == .persistent else { return }
        UserDefaults.standard.set(promptHistory, forKey: Self.promptHistoryKey)
    }

    /// Restore a prompt from history into the editor. Doesn't run anything;
    /// user explicitly triggers Run after picking.
    func loadPromptFromHistory(_ entry: String) {
        config.currentPrompt = entry
        persistAllDebounced()
    }

    private static let promptHistoryKey = "SHPromptHistory"
    private static let recentProjectsKey = "SHRecentProjects"
    private static let projectBookmarksKey = "SHProjectBookmarks"

    /// Posted by any view-model after a successful write to the shared
    /// recent-projects / project-bookmarks UserDefaults keys. Observed
    /// by every other view-model so a save in a scratch window shows up
    /// in the primary's `Otevřít nedávné…` menu (and vice versa)
    /// without an app restart. The notification's `object` is the
    /// posting view-model so receivers can skip their own posts.
    static let recentProjectsDidChange = Notification.Name(
        "DavidMasin.SpiceHarvester.recentProjectsDidChange"
    )

    // MARK: – Recent projects

    /// Pushes a project URL onto `recentProjectURLs` (most recent first,
    /// deduplicated by path, capped) and stores a security-scoped
    /// bookmark so the URL stays openable after app restart. Without
    /// the bookmark, sandboxed `Data(contentsOf: url)` calls fail with
    /// permission error once the original NSOpenPanel session ends.
    ///
    /// Project-file metadata is **inherently global** (the disk artifact
    /// exists for the whole user), so unlike prompt history / folder
    /// recents this write happens from scratch view-models too. Before
    /// mutating we resync from UserDefaults so a peer window's recent
    /// addition doesn't get clobbered by our stale in-memory snapshot.
    private func rememberProjectURL(_ url: URL) {
        // Pull latest from UserDefaults so we don't overwrite changes
        // made by another window since our last reload. Without this,
        // primary saves A, scratch saves B → scratch persists [B]
        // (loses A) because scratch's in-memory list was [].
        reloadRecentProjectsFromDefaults()

        let path = url.path
        recentProjectURLs.removeAll { $0.path == path }
        recentProjectURLs.insert(url, at: 0)
        if recentProjectURLs.count > Self.recentProjectsLimit {
            // Drop oldest entries from the URL list, plus their bookmarks
            // — keeps the bookmarks map from growing without bound for
            // users who churn through many projects.
            let evicted = recentProjectURLs.suffix(recentProjectURLs.count - Self.recentProjectsLimit)
            for url in evicted {
                projectBookmarks.removeValue(forKey: url.path)
            }
            recentProjectURLs.removeLast(recentProjectURLs.count - Self.recentProjectsLimit)
        }

        // Best-effort bookmark capture. Failure (e.g. user picked a path
        // outside the sandbox grant chain) is silently logged via the
        // missing key — Open Recent click later falls back to raw URL
        // and lets the user see the permission error.
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            projectBookmarks[path] = data
        }

        persistRecentProjectsAndBookmarks()
    }

    /// Drops a project URL (and its bookmark) from the recent list.
    /// Called when openProject hits a hard failure (file missing /
    /// unreadable / not a project file) — keeping a dead path in the
    /// menu just produces repeat error alerts.
    private func forgetProjectURL(_ url: URL) {
        reloadRecentProjectsFromDefaults()
        recentProjectURLs.removeAll { $0.path == url.path }
        projectBookmarks.removeValue(forKey: url.path)
        persistRecentProjectsAndBookmarks()
    }

    /// User-invoked clear from `File → Otevřít nedávné → Vyčistit`.
    /// Drops both the URL list and all stored bookmarks.
    func clearRecentProjects() {
        recentProjectURLs.removeAll()
        projectBookmarks.removeAll()
        let recentKey = Self.recentProjectsKey
        let bookmarksKey = Self.projectBookmarksKey
        let postName = Self.recentProjectsDidChange
        let weakSelf = self
        Task.detached(priority: .utility) {
            UserDefaults.standard.removeObject(forKey: recentKey)
            UserDefaults.standard.removeObject(forKey: bookmarksKey)
            // Hop to main for the post so observers (registered with
            // `.main` queue) receive on the expected queue and so the
            // `object` identity used for self-skip is stable.
            await MainActor.run {
                NotificationCenter.default.post(name: postName, object: weakSelf)
            }
        }
    }

    /// Re-reads `recentProjectURLs` + `projectBookmarks` from the shared
    /// UserDefaults keys. Idempotent. Called from init (initial load)
    /// AND from the cross-window observer when a peer view-model posts
    /// `recentProjectsDidChange`. Also called before any mutation so we
    /// merge over the latest persisted state instead of overwriting it.
    private func reloadRecentProjectsFromDefaults() {
        if let savedPaths = UserDefaults.standard.array(forKey: Self.recentProjectsKey) as? [String] {
            self.recentProjectURLs = savedPaths
                .prefix(Self.recentProjectsLimit)
                .map { URL(fileURLWithPath: $0) }
        } else {
            self.recentProjectURLs = []
        }
        if let savedBookmarks = UserDefaults.standard.dictionary(forKey: Self.projectBookmarksKey) as? [String: Data] {
            self.projectBookmarks = savedBookmarks
        } else {
            self.projectBookmarks = [:]
        }
    }

    /// Resolves a recent-project URL via its stored security-scoped
    /// bookmark and returns the fresh URL the caller can then bracket
    /// with `start/stopAccessingSecurityScopedResource`. Falls back to
    /// the input URL when no bookmark is stored — the caller's read
    /// will likely fail with permission error, which `openProject`
    /// handles by removing the URL from the recents list.
    ///
    /// Returns `(url, scopeStarted)` so the caller can correctly
    /// release the scope only if we actually started it.
    private func acquireProjectScope(for url: URL) -> (url: URL, scopeStarted: Bool) {
        guard let data = projectBookmarks[url.path] else {
            return (url, false)
        }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            // Bookmark unusable — drop it and fall back to plain URL.
            projectBookmarks.removeValue(forKey: url.path)
            return (url, false)
        }
        if isStale {
            // Refresh the bookmark in-place so next launch has fresh data.
            if let fresh = try? resolved.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                projectBookmarks[url.path] = fresh
                persistRecentProjectsAndBookmarks()
            }
        }
        let started = resolved.startAccessingSecurityScopedResource()
        return (resolved, started)
    }

    /// Bundles the dual-write of `recentProjectURLs` + `projectBookmarks`
    /// into a single off-main task. Centralised so every callsite
    /// (remember / forget / stale refresh) persists both in lockstep.
    /// After the write completes, broadcasts `recentProjectsDidChange`
    /// so peer view-models (other windows) refresh their menus.
    private func persistRecentProjectsAndBookmarks() {
        let paths = recentProjectURLs.map { $0.path }
        let bookmarks = projectBookmarks
        let postName = Self.recentProjectsDidChange
        let recentKey = Self.recentProjectsKey
        let bookmarksKey = Self.projectBookmarksKey
        let sender = self
        Task.detached(priority: .utility) {
            UserDefaults.standard.set(paths, forKey: recentKey)
            UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
            await MainActor.run {
                NotificationCenter.default.post(name: postName, object: sender)
            }
        }
    }

    // MARK: – Server health (manual recheck)

    /// Manual one-off ping on the verified server. Fires outside the
    /// 30 s ambient health watcher loop so the user can verify
    /// connectivity *now* (e.g. just restarted LM Studio) without
    /// waiting up to 30 s for the next scheduled poll. Updates
    /// `isVerifiedServerReachable` and `statusText`.
    func recheckServerNow() async {
        guard let server = selectedServer else {
            statusText = "Není vybraný server"
            return
        }
        guard isSelectedServerVerified else {
            statusText = "Server nejdřív ověř (Ověřit)"
            return
        }
        // Cancel any in-flight manual recheck so successive menu clicks
        // produce one ping, not a fan-out of retry chains.
        manualHealthCheckTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.statusText = "Kontroluji server…"
            do {
                let models = try await self.lmClient.fetchModels(server)
                guard !Task.isCancelled else { return }
                self.isVerifiedServerReachable = true
                self.statusText = "Server dostupný · modely: \(models.count)"
            } catch {
                guard !Task.isCancelled else { return }
                self.isVerifiedServerReachable = false
                self.statusText = "Server odpojen: \(error.localizedDescription)"
            }
        }
        manualHealthCheckTask = task
        await task.value
    }

    // MARK: – Save / Load Project (pragmatic DocumentGroup substitute)

    /// Encode current project state to a `.spiceharvester` JSON file
    /// chosen via NSSavePanel. Returns the chosen URL on success so the
    /// caller can show a confirmation; nil when the user cancelled.
    @discardableResult
    func saveProjectAs() -> URL? {
        let snapshot = SHProjectSnapshot(
            inputFolder: config.inputFolder,
            outputFolder: config.outputFolder,
            cacheFolder: config.cacheFolder,
            promptFolder: config.promptFolder,
            selectedInferenceModel: config.selectedInferenceModel,
            selectedEmbeddingModel: config.selectedEmbeddingModel,
            selectedRerankerModel: config.selectedRerankerModel,
            selectedOCRModel: config.selectedOCRModel,
            extractionMode: config.extractionMode,
            currentPrompt: config.currentPrompt,
            lastLoadedPromptName: config.lastLoadedPromptName
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Spice Harvester Project.spiceharvester.json"
        panel.title = "Uložit projekt jako…"
        panel.message = "Server registry, výkonové předvolby a runtime stav se neukládají — jen složky, vybrané modely, prompt a režim."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            rememberProjectURL(url)
            statusText = "Projekt uložen: \(url.lastPathComponent)"
            return url
        } catch {
            statusText = "Uložení projektu selhalo: \(error.localizedDescription)"
            return nil
        }
    }

    /// Restore project from a `.spiceharvester` JSON file. Server
    /// registry is intentionally NOT included in the snapshot — switching
    /// project shouldn't strip away the user's saved servers — but
    /// `selectedInferenceModel` and other model picks are restored, so
    /// they only "stick" if the same models are loaded on the current
    /// server.
    ///
    /// Sandboxing caveat: NSOpenPanel grants access to the chosen JSON
    /// file only, not to the folder paths described inside it. We use
    /// existing `folderBookmarks` for paths the user previously picked
    /// in this app; paths without a stored bookmark are loaded as
    /// strings only and the function returns the list of "stale" paths
    /// so the caller can warn the user to re-pick them.
    func openProject() -> SHOpenProjectOutcome {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "Otevřít projekt…"
        panel.message = "Vyber .spiceharvester.json soubor exportovaný přes Uložit projekt jako…"
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return openProject(at: url)
    }

    /// Direct-path variant of `openProject` used by `File → Otevřít
    /// nedávné…` menu items. Skips the open panel and decodes from the
    /// known URL. If decoding fails (file missing, format invalid), the
    /// URL is removed from `recentProjectURLs` so the menu doesn't keep
    /// listing a dead entry.
    ///
    /// Acquires the security-scoped bookmark stored at remember time so
    /// the read succeeds even across app restarts. The freshly-picked
    /// case (saveProjectAs / openProject just ran in this session) also
    /// works because the bookmark was just written.
    func openProject(at url: URL) -> SHOpenProjectOutcome {
        let scoped = acquireProjectScope(for: url)
        defer {
            if scoped.scopeStarted {
                scoped.url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: scoped.url)
            // Wrap the decode in a project-shaped sniff so a friendly
            // error replaces the noisy `keyNotFound(...)` cascade when
            // the user picks a random JSON. Validates one canonical
            // marker (`schemaVersion`) before going for the full decode.
            guard let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  probe["schemaVersion"] != nil else {
                // Same self-healing as the catch block below — dead
                // entries shouldn't keep haunting the Recent menu.
                forgetProjectURL(url)
                statusText = "Tento JSON není projekt Spice Harvester"
                return .failed(error: SHProjectError.notAProject(url: url))
            }
            let snapshot = try JSONDecoder().decode(SHProjectSnapshot.self, from: data)

            // Reset runtime state so the user doesn't see the previous
            // project's "Hotovo" banner / progress card after the
            // snapshot loads. Cached docs from the previous input are
            // dropped because the new snapshot may point at a different
            // folder (and even if same path, freshly invalidated is
            // safer than stale).
            lastCompletion = nil
            progressState = SHProgressViewState()
            cachedDocuments.removeAll()
            cachedDocumentsInputPath = ""
            // Project switch implies the user wants a fresh banner read;
            // a "Skrýt" dismissal that made sense for project A doesn't
            // necessarily apply to project B.
            dismissedConflictIDs.removeAll()

            // Apply the snapshot.
            config.inputFolder = snapshot.inputFolder
            config.outputFolder = snapshot.outputFolder
            config.cacheFolder = snapshot.cacheFolder
            config.promptFolder = snapshot.promptFolder
            config.selectedInferenceModel = snapshot.selectedInferenceModel
            config.selectedEmbeddingModel = snapshot.selectedEmbeddingModel
            config.selectedRerankerModel = snapshot.selectedRerankerModel
            config.selectedOCRModel = snapshot.selectedOCRModel
            config.extractionMode = snapshot.extractionMode
            config.currentPrompt = snapshot.currentPrompt
            config.lastLoadedPromptName = snapshot.lastLoadedPromptName

            // Detect paths that won't survive sandboxing — without an
            // existing bookmark in `config.folderBookmarks` we can't
            // open the folder. The view shows an alert so the user
            // knows to re-pick them via Vybrat.
            let stalePaths = staleSandboxPaths(in: snapshot)

            refreshInputFolderStats()
            scheduleConflictUpdate(after: 0)
            persistAll()
            rememberProjectURL(url)
            statusText = stalePaths.isEmpty
                ? "Projekt načten: \(url.lastPathComponent)"
                : "Projekt načten · \(stalePaths.count) složek vyžaduje re-pick"
            return stalePaths.isEmpty
                ? .success(url: url)
                : .successNeedsRepick(url: url, stalePaths: stalePaths)
        } catch {
            // Open Recent click hit a dead path — drop it so the user
            // doesn't see the same error every time they open the menu.
            forgetProjectURL(url)
            // Distinguish "sandbox refused the read because we have no
            // valid bookmark" from genuine I/O errors. The former
            // happens primarily across app restarts when the original
            // NSOpenPanel grant has expired and the stored bookmark
            // either didn't exist or failed to resolve — the
            // remediation is "re-pick via Cmd+O", not the generic
            // Cocoa error text.
            //
            // ONLY `NSFileReadNoPermissionError` qualifies. `NSFileNoSuchFileError`
            // means the file is genuinely missing (user deleted the
            // project file outside the app) — the remediation is
            // different, and a "vyžaduje re-grant" message would
            // mislead the user into clicking Cmd+O looking for a file
            // that no longer exists.
            let nsError = error as NSError
            let isPermissionError = nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSFileReadNoPermissionError
            if isPermissionError && !scoped.scopeStarted {
                let mapped = SHProjectError.permissionDenied(url: url)
                statusText = "Cesta vyžaduje re-grant — otevři projekt znovu (Cmd+O)"
                return .failed(error: mapped)
            }
            statusText = "Otevření projektu selhalo: \(error.localizedDescription)"
            return .failed(error: error)
        }
    }

    /// Returns paths from the snapshot that lack a stored security-scoped
    /// bookmark and can't be silently restored. The caller surfaces these
    /// to the user as an "re-pick required" warning. Empty paths (user
    /// hadn't set them in the saved project) are skipped.
    private func staleSandboxPaths(in snapshot: SHProjectSnapshot) -> [String] {
        var stale: [String] = []
        let candidates = [
            snapshot.inputFolder,
            snapshot.outputFolder,
            snapshot.cacheFolder,
            snapshot.promptFolder
        ]
        for path in candidates {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if config.folderBookmarks[trimmed] == nil {
                stale.append(trimmed)
            }
        }
        return stale
    }

    // MARK: – Recent folders

    /// Records `path` as the most recent entry for `kind`. Deduplicates
    /// (a path that's already on the list moves to the top instead of
    /// being added twice) and caps the list at `recentFoldersLimit`.
    /// Persisted to UserDefaults under a per-kind key.
    private func rememberRecentFolder(_ path: String, kind: SHFolderKind) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentFolders[kind] ?? []
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > Self.recentFoldersLimit {
            list.removeLast(list.count - Self.recentFoldersLimit)
        }
        recentFolders[kind] = list
        // Scratch windows skip the persistent write — same rationale as
        // recordPromptInHistory. In-memory list still updates so the
        // Recents menu in this scratch window reflects the new entry,
        // but the primary's stored list isn't touched.
        guard persistenceMode == .persistent else { return }
        // UserDefaults.set serializes through main thread by default;
        // for a single ~5-element string array per folder slot it's
        // submillisecond, but we move it off-main as a defensive
        // measure — folder picks happen in rapid succession when the
        // user is iterating projects, no reason to make Vybrat wait.
        let key = Self.recentFolderKey(for: kind)
        Task.detached(priority: .utility) {
            UserDefaults.standard.set(list, forKey: key)
        }
    }

    /// Recents for a given slot, freshest first. Empty when the user has
    /// never picked a folder of that kind. The current value is *not*
    /// filtered out — picking the same folder again is fine, just visible.
    func recents(for kind: SHFolderKind) -> [String] {
        recentFolders[kind] ?? []
    }

    /// Public hand-off used by folder rows when the user chooses an entry
    /// from the Recents menu. Mirrors what `pickFolder` does after
    /// `NSOpenPanel` returns: writes the path, refreshes scope-dependent
    /// caches, persists.
    func selectRecentFolder(_ path: String, kind: SHFolderKind) {
        switch kind {
        case .input:
            config.inputFolder = path
            invalidateCachedDocumentsIfInputChanged()
            refreshInputFolderStats()
        case .output:
            config.outputFolder = path
        case .cache:
            config.cacheFolder = path
        case .prompt:
            config.promptFolder = path
        }
        rememberRecentFolder(path, kind: kind)
        persistAll()
    }

    private static func recentFolderKey(for kind: SHFolderKind) -> String {
        "SHRecentFolders.\(kind.rawValue)"
    }

    func runExtraction() async {
        await executeRun {
            // If no cached docs yet, run preprocessing first – but inside the same
            // `isRunning = true` envelope so there's no flicker of the Run buttons.
            if self.cachedDocuments.isEmpty {
                let preOutcome = await self.performPreprocessing()
                if preOutcome != .success { return preOutcome }
            }
            guard !self.cachedDocuments.isEmpty else {
                self.statusText = "Žádná data pro extrakci"
                return .notStarted
            }
            return await self.performExtraction()
        }
    }

    func runAll() async {
        recordPromptInHistory()
        await executeRun {
            let preOutcome = await self.performPreprocessing()
            if preOutcome != .success { return preOutcome }
            guard !self.cachedDocuments.isEmpty else {
                self.statusText = "Předzpracování neprodukovalo žádná data – extrakce přeskočena"
                return .notStarted
            }
            return await self.performExtraction()
        }
    }

    /// Hydrates per-run overrides from `SHIntentNotifications.applyParameters`
    /// userInfo onto `config`. Called BEFORE `runAll` reads `config`, so
    /// the Shortcuts user can switch modes / prompts per workflow run
    /// without touching the persisted app state. Unknown keys are
    /// ignored; absent keys leave the existing value in place.
    ///
    /// **Ephemeral semantics:** before mutating, snapshot the original
    /// values into `intentOverrideRestore`. `broadcastRunDidComplete`
    /// rolls back to the snapshot at the end of the run so a Shortcut
    /// with `promptName: "lekarska"` doesn't permanently change the
    /// app's loaded prompt — the user's GUI state is exactly what it
    /// was before the Shortcut fired.
    ///
    /// The prompt lookup is name-based against the loaded prompt
    /// library — Shortcuts users typically type a stable filename
    /// (e.g. `lekarska-zprava.md`) rather than pasting a multi-KB
    /// prompt body into the action UI. Falls back silently when the
    /// name doesn't match (the run still proceeds with the previous
    /// prompt, and the failure surfaces in the result dialog via
    /// `statusText` when the user notices empty output).
    fileprivate func applyIntentParameters(_ userInfo: [AnyHashable: Any]) {
        // Snapshot BEFORE any mutation so restore is exact. If a
        // previous override is still pending restore (e.g. back-to-back
        // intent invocations without a runAll between them), keep the
        // older snapshot — that's the genuine pre-Shortcut state.
        if intentOverrideRestore == nil {
            intentOverrideRestore = (config.extractionMode, config.currentPrompt, config.lastLoadedPromptName)
        }

        if let raw = userInfo["mode"] as? String,
           let mode = SHExtractionMode(rawValue: raw) {
            config.extractionMode = mode
        }
        if let name = userInfo["promptName"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Match case-insensitively and tolerate the `.md` suffix
            // being missing — Shortcuts is a string field, users will
            // type whatever's quickest. Look in `availablePromptFiles`
            // first (already scanned), fall back to a fresh disk scan
            // when the picker hasn't been refreshed this session.
            let normalized = name.lowercased()
            let withSuffix = normalized.hasSuffix(".md") ? normalized : "\(normalized).md"
            if let match = availablePromptFiles.first(where: { url in
                let lower = url.lastPathComponent.lowercased()
                return lower == normalized || lower == withSuffix
            }) {
                // Read content directly instead of `loadPromptFile`
                // (which calls `persistAll`). The view's onChange
                // handler on `config.currentPrompt` still fires
                // `persistAllDebounced` 300 ms later, but our restore
                // path below resets the value before then most of the
                // time, and final `persistAll` overwrites any racing
                // debounced write with the restored snapshot.
                // `try?` on a function returning `String?` flattens to
                // `String?`, so a single `if let` captures both the
                // throw and the nil-resolve cases.
                if let loaded = try? withScopedAccess(to: config.promptFolder, { _ in
                    try promptService.loadContent(of: match)
                }) {
                    config.currentPrompt = loaded
                    config.lastLoadedPromptName = match.lastPathComponent
                }
            }
        }
    }

    /// Reverts config fields mutated by `applyIntentParameters` back
    /// to the pre-Shortcut snapshot. Called from `broadcastRunDidComplete`
    /// so the rollback runs regardless of how the run settled (success,
    /// cancel, failure, guard reject). No-op when no override is active.
    private func restoreIntentOverridesIfNeeded() {
        guard let restore = intentOverrideRestore else { return }
        intentOverrideRestore = nil
        // Only write back fields that actually changed — avoids a
        // pointless `persistAll` when the override was a no-op (e.g.
        // `mode` value matched current, `promptName` didn't resolve).
        var didChange = false
        if config.extractionMode != restore.mode {
            config.extractionMode = restore.mode
            didChange = true
        }
        if config.currentPrompt != restore.prompt {
            config.currentPrompt = restore.prompt
            didChange = true
        }
        if config.lastLoadedPromptName != restore.lastPromptName {
            config.lastLoadedPromptName = restore.lastPromptName
            didChange = true
        }
        if didChange {
            // Synchronous write overrides any pending debounced
            // persist scheduled by view onChange handlers during the
            // override window.
            persistAll()
        }
    }

    /// Cancel the currently running task (if any). A cancelled task propagates a
    /// `CancellationError` through the pipeline, which is surfaced as a warning in
    /// the status text.
    func cancelRun() {
        currentTask?.cancel()
    }

    /// Dismiss the completion badge so the Actions bar returns to its normal
    /// state with the "Předzpracování / Extrakce / Spustit / Vyčistit cache"
    /// buttons.
    func acknowledgeCompletion() {
        lastCompletion = nil
    }

    /// Single entry point for all long-running jobs. Enforces mutual exclusion and
    /// holds the `isRunning` flag for the **entire** duration, regardless of how
    /// many sub-phases `work` performs. Classifies the result strictly from the
    /// typed `SHRunOutcome` the worker returns – no more string matching against
    /// `statusText`, which caused guards like "Vyber vstupní složku" to register
    /// as successful completions.
    private func executeRun(_ work: @MainActor @escaping () async -> SHRunOutcome) async {
        guard !runEntered else {
            statusText = "Úloha už běží"
            return
        }
        // Cross-tab collision check: when the user has multiple
        // SpiceHarvester windows pointing at the same výstupní
        // složka, running both pipelines simultaneously would let
        // them overwrite each other's `results.csv` and interleave
        // partial JSONs. Block the second run with a clear message
        // and let the user either wait, cancel the other tab, or
        // point this tab at a different output folder.
        let normalizedOutput = Self.normalizeOutputPath(config.outputFolder)
        if !normalizedOutput.isEmpty {
            if let claimant = Self.activeOutputClaims[normalizedOutput], claimant !== self {
                let title = claimant.windowTitle
                statusText = "Výstupní složka je zaneprázdněná jinou záložkou (\(title)) — počkej, nebo zvol jinou."
                return
            }
            Self.activeOutputClaims[normalizedOutput] = self
        }
        // Clear any stale badge from a previous run.
        lastCompletion = nil
        // Reset summary fields so a `.notStarted` (pre-condition fail)
        // or `.failed` outcome doesn't carry stale counts from the
        // previous run into the `runDidComplete` payload.
        lastRunDocumentCount = 0
        lastRunCSVPath = ""
        runEntered = true
        isRunning = true

        let task = Task { @MainActor () -> SHRunOutcome in
            await work()
        }
        // Store the actual work task so `cancelRun()` → `currentTask.cancel()`
        // propagates cancellation into the pipeline (vs. a wrapper task where
        // the cancellation wouldn't reach the child).
        currentTask = task
        let outcome = await task.value

        switch outcome {
        case .success:
            lastCompletion = .success
        case .cancelled:
            lastCompletion = .cancelled
        case .failed:
            lastCompletion = .failed
        case .notStarted:
            // Pre-condition failed (e.g. no input folder) – no badge at all so the
            // Actions bar stays in its "ready" state and the user can correct the
            // missing input.
            lastCompletion = nil
        }

        // Surface completion via Notification Center when the app is in the
        // background — long batches (30+ min) often run while the user has
        // switched to other work, and silent in-app banner is missed. We
        // suppress the notification when the app is the frontmost active
        // app: the in-app banner already covers that case.
        if outcome != .notStarted, !NSApp.isActive {
            postCompletionNotification(for: outcome)
        }

        // Release the output-folder claim so the next run in any tab
        // (this one or another) can proceed. Guard on identity in
        // case the user changed `outputFolder` mid-run via Settings
        // — we should only release a claim we actually placed.
        if !normalizedOutput.isEmpty, Self.activeOutputClaims[normalizedOutput] === self {
            Self.activeOutputClaims.removeValue(forKey: normalizedOutput)
        }

        isRunning = false
        runEntered = false
        currentTask = nil
    }

    /// Path → vm registry of output folders currently being written
    /// by an active run. Read + mutated only on the main actor (vm
    /// is `@MainActor`-isolated and so is this static), so a plain
    /// dictionary suffices — no `Lock` / `Mutex` needed. Held
    /// `weak`-ish via class identity: if a vm goes away mid-run its
    /// entry just becomes a dangling key, but `executeRun`'s identity
    /// check (`claimant !== self`) only blocks live claimants, so
    /// stale entries are self-healing on next run attempt.
    @MainActor private static var activeOutputClaims: [String: SHAppViewModel] = [:]

    /// Process-wide weak registry of every live SHAppViewModel.
    /// Populated in `init`, auto-pruned on dealloc (weak refs).
    /// Consumed by `runFromIntent` so a Shortcuts.app AppIntent can
    /// target a specific window/tab by its input-folder name instead
    /// of always firing on the primary vm.
    @MainActor static let liveRegistry: NSHashTable<SHAppViewModel> = .weakObjects()

    /// Entry point for `RunSpiceHarvesterIntent`. Replaces the
    /// previous NotificationCenter dance (post `applyParameters`,
    /// post `runAll`, await `runDidComplete`) with a direct method
    /// call on the resolved target vm. Direct call eliminates two
    /// races:
    ///   1. Multiple vms claiming the same `runAll` broadcast
    ///   2. Intent observer matching the wrong vm's `runDidComplete`
    ///
    /// Target resolution:
    ///   - `inputFolderName` is set → first live vm whose
    ///     `config.inputFolder` lastPathComponent matches
    ///     (case-insensitive). Returns `notStarted` with explanation
    ///     when no match is found.
    ///   - `inputFolderName` is nil → falls back to the `.persistent`
    ///     (primary) vm. Behaviour is the same as the pre-refactor
    ///     intent, which only ever spoke to primary.
    ///
    /// Per-run overrides (mode / prompt) are applied via the existing
    /// snapshot/restore mechanism so the user's GUI state isn't
    /// permanently mutated by a Shortcut.
    @MainActor
    static func runFromIntent(
        targetFolder: String?,
        mode: String?,
        promptName: String?
    ) async -> (outcome: String, documentCount: Int, csvPath: String, statusText: String) {
        let resolved = resolveIntentTarget(targetFolder: targetFolder)
        guard let vm = resolved.vm else {
            return ("notStarted", 0, "", resolved.failureMessage ?? "Cílová záložka nenalezena")
        }

        // Pre-flight: reject early if the vm can't accept a run,
        // BEFORE applying any per-run overrides. Avoids a brief
        // UI flicker where the user sees the mode picker or prompt
        // text editor switch to the override value and then snap
        // back when we restore in the reject path.
        //
        // We test canRunAll against the CURRENT config, not the
        // overridden one, because the user's "is this tab ready"
        // mental model is the unchanged state. If `mode: .search`
        // override would itself unblock the run (e.g. by switching
        // to a mode that doesn't need an embedding model the user
        // hasn't configured), the user can fix that themselves and
        // re-trigger the Shortcut.
        guard !vm.isRunning, vm.canRunAll else {
            return ("notStarted", 0, "", vm.toolbarReadyText)
        }

        // Best-effort: surface the target tab so the user sees the
        // progress in the right window. NSApp.activate brings the
        // app forward (already done by `openAppWhenRun: true`),
        // makeKeyAndOrderFront brings the specific NSWindow forward
        // — important in tabbed-window groups where the focused
        // tab won't change just because the app activates. Match
        // by `windowTitle` which we set via `.navigationTitle`.
        let targetTitle = vm.windowTitle
        if let window = NSApp.windows.first(where: { $0.title == targetTitle }) {
            window.makeKeyAndOrderFront(nil)
        }

        var overrides: [String: Any] = [:]
        if let mode { overrides["mode"] = mode }
        if let promptName { overrides["promptName"] = promptName }
        if !overrides.isEmpty {
            vm.applyIntentParameters(overrides)
        }
        await vm.runAll()
        // Restore overrides — moved out of `broadcastRunDidComplete`
        // when we switched from NotificationCenter to direct-call
        // semantics; restoration now happens locally so it's
        // guaranteed even when the run ends in `.failed` /
        // `.cancelled` (which `runAll` swallows internally).
        vm.restoreIntentOverridesIfNeeded()
        let outcomeStr: String
        switch vm.lastCompletion {
        case .success?: outcomeStr = "success"
        case .cancelled?: outcomeStr = "cancelled"
        case .failed?: outcomeStr = "failed"
        case .none: outcomeStr = "notStarted"
        }
        return (outcomeStr, vm.lastRunDocumentCount, vm.lastRunCSVPath, vm.statusText)
    }

    /// Looks up the vm an intent invocation should run on.
    /// Tuple's `failureMessage` is non-nil when no vm matched and we
    /// want a specific user-facing explanation (e.g. "the folder X
    /// isn't loaded in any tab").
    @MainActor
    private static func resolveIntentTarget(
        targetFolder: String?
    ) -> (vm: SHAppViewModel?, failureMessage: String?) {
        let live = liveRegistry.allObjects
        if let target = targetFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty {
            for vm in live {
                let name = (vm.config.inputFolder as NSString).lastPathComponent
                if name.compare(target, options: .caseInsensitive) == .orderedSame {
                    return (vm, nil)
                }
            }
            return (nil, "Žádná otevřená záložka nemá vstupní složku: \(target)")
        }
        // No target → primary fallback (backward-compatible behavior
        // with pre-targeting intent invocations).
        let primary = live.first { $0.persistenceMode == .persistent }
        return (primary, primary == nil ? "Hlavní okno není dostupné" : nil)
    }

    /// Canonical form of a path string for collision matching:
    /// strips trailing slash, resolves `~`, removes `.`/`..` segments.
    /// Empty input → empty output (caller's guard for "no folder set").
    private static func normalizeOutputPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).standardizingPath
    }

    // MARK: – Notification Center

    // Notification authorization & category registration moved to
    // `SHAppDelegate.applicationDidFinishLaunching` (process-singleton).

    private func postCompletionNotification(for outcome: SHRunOutcome) {
        let content = UNMutableNotificationContent()
        // Set categoryIdentifier so the system attaches the "Otevřít
        // výstup" action button defined in `setNotificationCategories`.
        content.categoryIdentifier = SHCompletionNotification.categoryID
        // Notification banners appear on the lock screen by default and
        // are visible to anyone who can see the user's display. The
        // pipeline's `statusText` may contain filenames, error messages
        // and (in the medical-records context this app was originally
        // built for) PHI fragments. Use minimal, generic body text and
        // let the user open the app for the full status.
        switch outcome {
        case .success:
            content.title = "Spice Harvester: hotovo"
            content.body = "Pipeline byla úspěšně dokončena. Klikni Otevřít výstup pro výsledky."
            content.sound = .default
        case .cancelled:
            content.title = "Spice Harvester: přerušeno"
            content.body = "Běh byl přerušen uživatelem."
        case .failed:
            content.title = "Spice Harvester: chyba"
            content.body = "Pipeline selhala. Detaily v hlavním okně aplikace."
            content.sound = .default
        case .notStarted:
            return
        }
        // Immediate delivery; nil trigger means "now". Identifier is
        // unique-per-completion so multiple runs don't replace each other.
        let request = UNNotificationRequest(
            identifier: "spiceharvester.completion.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func performPreprocessing() async -> SHRunOutcome {
        guard let inputURL = resolveScopedURL(for: config.inputFolder) else {
            statusText = "Vyber vstupní složku"
            return .notStarted
        }

        let inputScope = inputURL.startAccessingSecurityScopedResource()
        defer { if inputScope { inputURL.stopAccessingSecurityScopedResource() } }

        let (cacheRoot, cacheScoped) = resolveCacheRoot()
        defer { if cacheScoped { cacheRoot.stopAccessingSecurityScopedResource() } }

        let outputURL = resolveScopedURL(for: config.outputFolder)
        let outputScope = outputURL?.startAccessingSecurityScopedResource() ?? false
        defer { if outputScope, let outputURL { outputURL.stopAccessingSecurityScopedResource() } }

        await benchmarkService.reset()
        progressState = SHProgressViewState()
        progressState.startedAt = Date()
        progressState.phase = .preprocessing
        statusText = "Spouštím předzpracování"
        resetItemTracking()

        do {
            let logger = try ensureLogger(outputURL: outputURL)
            let cache = SHCacheManager(cacheRoot: cacheRoot)
            self.cacheManager = cache
            // Inference cache lives next to the document cache so "Vyčistit cache"
            // can nuke both in one shot.
            self.inferenceCache = SHInferenceCache(cacheRoot: cacheRoot)
            self.embeddingCache = SHEmbeddingCache(cacheRoot: cacheRoot)

            let ocrProvider = try makeOCRProvider()
            let pipeline = SHPreprocessingPipeline(
                ocrProvider: ocrProvider,
                cacheManager: cache,
                logger: logger,
                benchmark: benchmarkService,
                maxConcurrentWorkers: config.maxConcurrentPDFWorkers,
                preprocessingSignature: preprocessingSignature()
            )

            let output = await pipeline.run(
                inputFolder: inputURL,
                onCounters: { [weak self] counters in
                    await MainActor.run { [weak self] in
                        self?.applyCounters(counters)
                        self?.recalculateEta()
                    }
                },
                onItemEvent: { [weak self] event in
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        switch event {
                        case .started(let name): self.itemStarted(name)
                        case .finished(let name): self.itemFinished(name)
                        }
                    }
                }
            )

            cachedDocuments = output.cachedDocuments
            cachedDocumentsInputPath = config.inputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            benchmark = await benchmarkService.current()
            logText = await logger.readTail()
            if Task.isCancelled {
                progressState.phase = .finished
                statusText = "Předzpracování přerušeno uživatelem (\(output.cachedDocuments.count) dokumentů)"
                return .cancelled
            }
            updateBaselineFromBenchmark()
            progressState.phase = .finished
            statusText = "Předzpracování dokončeno (\(output.cachedDocuments.count) dokumentů)"
            return .success
        } catch is CancellationError {
            progressState.phase = .finished
            statusText = "Předzpracování přerušeno uživatelem"
            return .cancelled
        } catch {
            progressState.phase = .finished
            statusText = "Chyba předzpracování: \(error.localizedDescription)"
            return .failed
        }
    }

    /// Silently refreshes `config.modelContextTokens` from LM Studio right before
    /// a CONSOLIDATE run. If the user restarted the model with a different context
    /// length in LM Studio after the last "Ověřit server", the cached value is
    /// stale and the pre-flight check would use the wrong limit. Best-effort –
    /// failure is ignored (e.g. non-LM-Studio servers don't have this endpoint).
    private func refreshContextIfRelevant() async {
        guard config.extractionMode == .consolidate,
              let server = selectedServer else { return }
        guard let loaded = try? await lmClient.fetchLoadedModels(server) else { return }
        let trimmed = config.selectedInferenceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = loaded.first { $0.id == trimmed }
            ?? loaded.first { $0.state?.lowercased() == "loaded" }
            ?? loaded.first
        if let detected = target?.effectiveContextLength, detected != config.modelContextTokens {
            config.modelContextTokens = detected
            persistAll()
        }
    }

    private func performExtraction() async -> SHRunOutcome {
        guard let server = selectedServer else {
            statusText = "Není vybraný server"
            return .notStarted
        }
        guard !config.selectedInferenceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusText = "Vyber inference model"
            return .notStarted
        }
        let trimmedPrompt = config.currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptWithoutThinkingMarker(trimmedPrompt).isEmpty else {
            statusText = "Zadej prompt"
            return .notStarted
        }
        guard let outputURL = resolveScopedURL(for: config.outputFolder) else {
            statusText = "Vyber výstupní složku"
            return .notStarted
        }

        guard !cachedDocuments.isEmpty else {
            statusText = "Žádná data pro extrakci"
            return .notStarted
        }

        // CONSOLIDATE pre-flight: if the in-memory baseline says this batch is
        // close to the configured model context, silently re-fetch the live
        // context from LM Studio. Catches the case where the user reloaded the
        // model with a different context size since the last `Ověřit server`.
        if config.extractionMode == .consolidate {
            await refreshModelContextIfRisky(server: server)
        }

        let outputScope = outputURL.startAccessingSecurityScopedResource()
        defer { if outputScope { outputURL.stopAccessingSecurityScopedResource() } }

        // Reset per-run progress so ETA is computed from the extraction start,
        // not from preprocessing start (which would now be in the past).
        // Initialise foundPDFs + cachedDocs so the Progress card has meaningful
        // values immediately (otherwise "V cache" showed 0 during extraction even
        // though all N docs are by definition being fed from the cache).
        progressState = SHProgressViewState()
        progressState.counters.foundPDFs = cachedDocuments.count
        progressState.counters.cachedDocs = cachedDocuments.count
        progressState.startedAt = Date()
        progressState.phase = .extraction
        progressState.extractionProgressCompleted = 0
        progressState.extractionProgressTotal = cachedDocuments.count
        progressState.extractionProgressLabel = "dokumentů"
        statusText = "Spouštím extrakci"
        resetItemTracking()

        // For CONSOLIDATE batches, re-fetch the model's loaded context length
        // from LM Studio so the pre-flight check works against the current model
        // state (user may have restarted LM Studio with a different context
        // since the last "Ověřit server").
        await refreshContextIfRelevant()

        // The inference cache needs security scope on the user-picked cache folder
        // for the ENTIRE run. Acquire it here (function scope), not inside a nested
        // `if` where `defer` would release it immediately after cache construction.
        let (cacheRoot, cacheScoped) = resolveCacheRoot()
        defer { if cacheScoped { cacheRoot.stopAccessingSecurityScopedResource() } }
        if inferenceCache == nil {
            inferenceCache = SHInferenceCache(cacheRoot: cacheRoot)
        }
        if embeddingCache == nil {
            embeddingCache = SHEmbeddingCache(cacheRoot: cacheRoot)
        }

        do {
            let logger = try ensureLogger(outputURL: outputURL)

            let pipeline = SHExtractionPipeline(
                lmClient: lmClient,
                logger: logger,
                benchmark: benchmarkService,
                maxConcurrentInference: max(1, config.maxConcurrentInference),
                throttleDelayMs: config.throttleDelayMs,
                modelContextTokens: config.modelContextTokens,
                inferenceCache: inferenceCache,
                embeddingCache: embeddingCache,
                bypassInferenceCache: config.bypassInferenceCache
            )

            let promptID = config.lastLoadedPromptName.isEmpty
                ? "user"
                : URL(fileURLWithPath: config.lastLoadedPromptName).deletingPathExtension().lastPathComponent
            let activePrompt = SHPromptTemplate(id: promptID, title: promptID, content: trimmedPrompt)

            let results = await pipeline.run(
                documents: cachedDocuments,
                prompts: [activePrompt],
                mode: config.extractionMode,
                server: server,
                inferenceModel: config.selectedInferenceModel,
                embeddingModel: config.selectedEmbeddingModel,
                rerankerModel: config.selectedRerankerModel,
                onProgress: { [weak self] completed, total, kind in
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        let documentTotal = self.cachedDocuments.count
                        self.applyExtractionProgress(
                            completed: completed,
                            total: total,
                            label: kind == .documents ? "dokumentů" : "LM kroků",
                            documentCompleted: kind == .documents ? completed : self.progressState.counters.completed,
                            documentTotal: documentTotal
                        )
                        self.recalculateEta()
                    }
                },
                onItemEvent: { [weak self] event in
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        switch event {
                        case .started(let name): self.itemStarted(name)
                        case .finished(let name): self.itemFinished(name)
                        }
                    }
                }
            )

            try exportService.exportAll(results: results, outputFolder: outputURL)
            benchmark = await benchmarkService.current()
            logText = await logger.readTail()

            let cacheHits = pipeline.cacheHits()
            let cacheSuffix = cacheHits > 0 ? " · \(cacheHits)× cache hit" : ""

            // Snapshot summary fields for the Shortcuts/AppIntent
            // bridge. `executeRun` reads these after the worker
            // returns and includes them in the `runDidComplete`
            // userInfo payload. `exportAll` writes `results.csv` into
            // `outputURL` — hardcoded filename matches `SHExportService`.
            lastRunDocumentCount = results.count
            lastRunCSVPath = outputURL.appendingPathComponent("results.csv").path

            if Task.isCancelled {
                progressState.phase = .finished
                statusText = "Extrakce přerušena uživatelem (\(results.count) dokumentů)\(cacheSuffix)"
                return .cancelled
            }
            updateBaselineFromBenchmark()
            progressState.phase = .finished
            statusText = "Extrakce dokončena (\(results.count) dokumentů)\(cacheSuffix)"
            return .success
        } catch is CancellationError {
            progressState.phase = .finished
            statusText = "Extrakce přerušena uživatelem"
            return .cancelled
        } catch {
            progressState.phase = .finished
            statusText = "Chyba extrakce: \(error.localizedDescription)"
            return .failed
        }
    }

    private func makeOCRProvider() throws -> SHOCRProviding {
        switch config.ocrBackend {
        case .appleVision:
            return SHVisionOCRProvider()
        case .openAIVision:
            guard let server = selectedServer else {
                throw SHRunConfigurationError.missingOCRServer
            }
            let model = config.selectedOCRModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                throw SHRunConfigurationError.missingOCRModel
            }
            return SHOpenAIVisionOCRProvider(client: lmClient, server: server, model: model)
        case .appleVisionThenOpenAI:
            guard let server = selectedServer else {
                throw SHRunConfigurationError.missingOCRServer
            }
            let model = config.selectedOCRModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                throw SHRunConfigurationError.missingOCRModel
            }
            let fallback = SHOpenAIVisionOCRProvider(client: lmClient, server: server, model: model)
            return SHFallbackOCRProvider(primary: SHVisionOCRProvider(), fallback: fallback)
        }
    }

    private func preprocessingSignature() -> String {
        switch config.ocrBackend {
        case .appleVision:
            return "ocr=appleVision"
        case .openAIVision:
            return "ocr=openAIVision;model=\(config.selectedOCRModel)"
        case .appleVisionThenOpenAI:
            return "ocr=appleVisionThenOpenAI;model=\(config.selectedOCRModel)"
        }
    }

    func clearCache() async {
        guard !runEntered else {
            statusText = "Úloha už běží – cache nelze čistit během běhu"
            return
        }
        let (cacheRoot, scoped) = resolveCacheRoot()
        defer { if scoped { cacheRoot.stopAccessingSecurityScopedResource() } }

        let docCache = SHCacheManager(cacheRoot: cacheRoot)
        await docCache.clear()
        // Also nuke the inference cache – users typically click "Vyčistit cache"
        // to force a fresh run, and keeping stale LLM responses around would
        // defeat that intent. Cheap – it's just JSON files in a sibling dir.
        let infCache = SHInferenceCache(cacheRoot: cacheRoot)
        await infCache.clear()
        inferenceCache = infCache
        let embCache = SHEmbeddingCache(cacheRoot: cacheRoot)
        await embCache.clear()
        embeddingCache = embCache

        cachedDocuments.removeAll()
        cachedDocumentsInputPath = ""
        progressState.counters.cachedDocs = 0
        statusText = "Cache vyčištěna (dokumenty + LLM odpovědi)"
    }

    func openOutput() {
        guard let outputURL = resolveScopedURL(for: config.outputFolder) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outputURL.path)
    }

    func refreshLog() async {
        guard let logger else { return }
        logText = await logger.readTail()
        benchmark = await benchmarkService.current()
    }

    /// Assigns new counters and bumps `lastProgressAt` iff any of the tracked
    /// fields actually incremented. Used by the progress card's health indicator
    /// to distinguish "running, moving" from "running, silent for N seconds".
    private func applyCounters(_ next: SHPipelineCounters) {
        let old = progressState.counters
        let advanced = next.completed > old.completed
            || next.cachedDocs > old.cachedDocs
            || next.newlyOCRed > old.newlyOCRed
            || next.foundPDFs > old.foundPDFs
        progressState.counters = next
        if advanced {
            progressState.lastProgressAt = Date()
        }
    }

    private func applyExtractionProgress(
        completed: Int,
        total: Int,
        label: String,
        documentCompleted: Int,
        documentTotal: Int
    ) {
        let advanced = completed > progressState.extractionProgressCompleted
            || total > progressState.extractionProgressTotal
            || documentCompleted > progressState.counters.completed
        progressState.extractionProgressCompleted = completed
        progressState.extractionProgressTotal = total
        progressState.extractionProgressLabel = label
        progressState.counters.completed = documentCompleted
        progressState.counters.foundPDFs = documentTotal
        if advanced {
            progressState.lastProgressAt = Date()
        }
    }

    private func recalculateEta() {
        // Pick the counter that actually advances in the current phase: preprocessing
        // increments `cachedDocs`, extraction increments `completed`. Without this
        // split, ETA stayed at "—" during the whole preprocessing run.
        let done: Int
        switch progressState.phase {
        case .preprocessing: done = progressState.counters.cachedDocs
        case .extraction:    done = progressState.extractionProgressCompleted
        case .idle, .finished: done = 0
        }
        let total: Int
        switch progressState.phase {
        case .preprocessing: total = progressState.counters.foundPDFs
        case .extraction:    total = progressState.extractionProgressTotal
        case .idle, .finished: total = 0
        }
        guard done > 0, total > 0, let start = progressState.startedAt else {
            progressState.averageDocumentSeconds = 0
            progressState.etaSeconds = 0
            return
        }

        let elapsed = Date().timeIntervalSince(start)
        let avg = elapsed / Double(done)
        progressState.averageDocumentSeconds = avg
        progressState.etaSeconds = avg * Double(max(total - done, 0))
    }

    /// Opens `NSOpenPanel` pre-positioned in the most useful directory:
    /// 1. If this row already has a value, start in that value's **parent**
    ///    (user is replacing the path and likely wants a sibling folder).
    /// 2. Otherwise, start in the parent of the most recently picked folder
    ///    anywhere in the app (project-sibling shortcut).
    /// 3. Otherwise, let NSOpenPanel pick its default location.
    private func chooseFolder(relativeTo currentPath: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Vybrat"

        if let trimmed = currentPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty,
           FileManager.default.fileExists(atPath: trimmed) {
            panel.directoryURL = URL(fileURLWithPath: trimmed).deletingLastPathComponent()
        } else if let parent = lastPickedFolderParent,
                  FileManager.default.fileExists(atPath: parent.path) {
            panel.directoryURL = parent
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Remember this pick's parent so the NEXT picker without its own value
        // also lands in the same project directory.
        lastPickedFolderParent = url.deletingLastPathComponent()
        return url
    }

    /// Resolves the given config-stored path, acquires a security-scoped
    /// resource on the resulting URL, runs the body, and releases the scope on
    /// exit – even if `body` throws. Returns `nil` (skipping `body`) when the
    /// path is empty or can't be resolved. Consolidates the 4× scoped-access
    /// pattern that lived inline in `chooseFolder`, `reloadPromptFiles`,
    /// `loadPromptFile`, and `openOutput`.
    @discardableResult
    private func withScopedAccess<T>(
        to path: String,
        _ body: (URL) throws -> T
    ) rethrows -> T? {
        guard let url = resolveScopedURL(for: path) else { return nil }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    /// Async variant of `withScopedAccess` for bodies that need to `await`.
    @discardableResult
    private func withScopedAccessAsync<T>(
        to path: String,
        _ body: (URL) async throws -> T
    ) async rethrows -> T? {
        guard let url = resolveScopedURL(for: path) else { return nil }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try await body(url)
    }

    private func storeBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        config.folderBookmarks[url.path] = data
    }

    /// Resolves a stored path to a URL. If a security-scoped bookmark exists it is used
    /// (and refreshed when stale); otherwise a plain file URL is returned, which only
    /// works inside the session the folder was selected in.
    ///
    /// Any mutation of `config.folderBookmarks` (drop of unusable bookmark, refresh of
    /// stale bookmark) is persisted immediately so the next launch sees the fix.
    private func resolveScopedURL(for path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = config.folderBookmarks[trimmed] else {
            return URL(fileURLWithPath: trimmed)
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            // Bookmark is unusable – drop it and fall back to the raw path.
            config.folderBookmarks.removeValue(forKey: trimmed)
            persistAll()
            return URL(fileURLWithPath: trimmed)
        }

        if isStale {
            if let fresh = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                config.folderBookmarks[url.path] = fresh
                if url.path != trimmed {
                    config.folderBookmarks.removeValue(forKey: trimmed)
                }
                persistAll()
            }
        }
        return url
    }

    /// Returns the cache directory URL along with a flag indicating whether the caller
    /// is responsible for calling `stopAccessingSecurityScopedResource()` on it.
    /// For the default app cache directory (inside the sandbox container) no scoping is needed.
    private func resolveCacheRoot() -> (url: URL, scoped: Bool) {
        if let user = resolveScopedURL(for: config.cacheFolder) {
            let scoped = user.startAccessingSecurityScopedResource()
            return (user, scoped)
        }

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = base.appendingPathComponent("SpiceHarvesterCache")
        config.cacheFolder = url.path
        persistAll()
        return (url, false)
    }

    /// Returns a logger rooted in the current output folder. Reuses the existing
    /// logger iff the output folder hasn't changed since it was created – otherwise
    /// closes it and opens a new one in the correct location. Fixes the bug where
    /// the logger kept writing to the previous folder after the user switched.
    private func ensureLogger(outputURL: URL? = nil) throws -> SHProcessingLogger {
        let output = outputURL
            ?? resolveScopedURL(for: config.outputFolder)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        if let existing = logger, loggerOutputPath == output.path {
            return existing
        }

        let logURL = output.appendingPathComponent("processing.log")
        let newLogger = SHProcessingLogger(logFileURL: logURL)
        logger = newLogger
        loggerOutputPath = output.path
        return newLogger
    }
}

/// Identifier constants for the completion notification category and its
/// action buttons. Producer (`postCompletionNotification`) and consumer
/// (`SHNotificationDelegate`) both reference these strings, so they live
/// in one place.
enum SHCompletionNotification {
    static let categoryID = "DavidMasin.SpiceHarvester.completion"
    static let openOutputActionID = "OPEN_OUTPUT"
}
