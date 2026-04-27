import Foundation
import SwiftUI
import AppKit
import Observation

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
    var statusText: String = "Připraveno"
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

    /// Is the currently selected server's last verification still valid?
    var isSelectedServerVerified: Bool {
        guard let id = verifiedServerID, let current = selectedServer else { return false }
        return id == current.id
    }

    /// Invalidate the "verified" badge whenever the server's identity or credentials
    /// change (URL or API key edit, server switch, etc.).
    func invalidateServerVerification() {
        verifiedServerID = nil
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

    var toolbarReadyText: String {
        if isRunning { return "Zpracovávám…" }
        if !hasAllInputFolders { return "Zadej cesty ke složkám" }
        if !hasModelParameters { return "Nastav parametry modelu" }
        if !hasPrompt { return "Zadej prompt nebo ho načti ze seznamu" }
        if canRunAll { return "Můžeš spustit" }
        return "Nastav parametry modelu"
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
    /// True for the brief window where a task is about to start – guards against
    /// back-to-back clicks racing past the `isRunning` flag.
    private var runEntered: Bool = false
    /// Parent directory of the folder picked most recently in this session. Used
    /// as the starting location for subsequent folder pickers so project siblings
    /// (Vstup / Výstup / Cache / Prompty) are one click away instead of navigating
    /// from home every time. Session-only; not persisted.
    private var lastPickedFolderParent: URL?

    init() {
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
        // UserDefaults between launches.
        configStore.save(config)

        // Build the OpenAI-compatible client with the persisted timeout preference (so the
        // user's last chosen value is in effect immediately, not only after they
        // first touch the stepper).
        rebuildLMClient()

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
        configStore.save(config)
        serverStore.saveServers(servers)
    }

    /// Debounced variant for keystroke-driven bindings (prompt text, server URL).
    /// Writes to UserDefaults only after the user pauses for `delayMs` ms, so long
    /// edits don't hammer disk on every character.
    private var persistDebounceTask: Task<Void, Never>?
    func persistAllDebounced(delayMs: Int = 300) {
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.configStore.save(self?.config ?? SHAppConfig())
            self?.serverStore.saveServers(self?.servers ?? [])
        }
    }

    func chooseInputFolder() { pickFolder(into: \.inputFolder) { self.invalidateCachedDocumentsIfInputChanged() } }
    func chooseOutputFolder() { pickFolder(into: \.outputFolder) }
    func chooseCacheFolder() { pickFolder(into: \.cacheFolder) }
    func choosePromptFolder() { pickFolder(into: \.promptFolder) }

    /// Opens the folder picker and, on success, writes the chosen path into
    /// `config[keyPath:]`, stores its security-scoped bookmark, and persists.
    /// `onChange` fires after the write, for side effects like cache invalidation.
    private func pickFolder(into keyPath: WritableKeyPath<SHAppConfig, String>,
                            onChange: (() -> Void)? = nil) {
        let currentValue = config[keyPath: keyPath]
        guard let url = chooseFolder(relativeTo: currentValue) else { return }
        config[keyPath: keyPath] = url.path
        storeBookmark(for: url)
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
            persistAll()
            statusText = "Server dostupný · modely: \(models.count)\(contextSuffix)"
            validateSelectedEmbeddingModel()
        } catch {
            if verifiedServerID == server.id {
                verifiedServerID = nil
            }
            statusText = "Ověření selhalo: \(error.localizedDescription)"
        }
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
        // Clear any stale badge from a previous run.
        lastCompletion = nil
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

        isRunning = false
        runEntered = false
        currentTask = nil
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

            let output = await pipeline.run(inputFolder: inputURL) { [weak self] counters in
                await MainActor.run { [weak self] in
                    self?.applyCounters(counters)
                    self?.recalculateEta()
                }
            }

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
                }
            )

            try exportService.exportAll(results: results, outputFolder: outputURL)
            benchmark = await benchmarkService.current()
            logText = await logger.readTail()

            let cacheHits = pipeline.cacheHits()
            let cacheSuffix = cacheHits > 0 ? " · \(cacheHits)× cache hit" : ""

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
