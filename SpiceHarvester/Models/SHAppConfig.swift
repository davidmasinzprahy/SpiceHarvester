import Foundation

enum SHExtractionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Per-document inference, no RAG. One request per PDF.
    case fast
    /// Per-document inference with embedding-based context selection (RAG).
    case search
    /// All documents concatenated into one request, one aggregated response.
    /// Useful when the prompt expects a single JSON array across the whole batch.
    /// Requires a model with a large context window.
    case consolidate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "FAST"
        case .search: return "SEARCH"
        case .consolidate: return "CONSOLIDATE"
        }
    }
}

enum SHOCRBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Use Apple Vision OCR only.
    case appleVision
    /// Send rendered PDF pages to an OpenAI-compatible VLM/OCR model.
    case openAIVision
    /// Try Apple Vision first and use OpenAI-compatible VLM/OCR only when Vision
    /// returns no usable text.
    case appleVisionThenOpenAI
    /// Lokální OCR přes ocrmypdf (tesseract). Fallback na Apple Vision při chybě.
    case ocrmypdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleVision: return "Apple Vision"
        case .openAIVision: return "oMLX/VLM"
        case .appleVisionThenOpenAI: return "Vision→VLM"
        case .ocrmypdf: return "ocrmypdf"
        }
    }
}

struct SHServerConfig: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String
    /// Optional bearer token sent in `Authorization: Bearer <apiKey>` header.
    /// Empty by default (LM Studio's default config doesn't require auth).
    ///
    /// **Drženo jen v paměti za běhu** — záměrně **mimo `Codable`** (viz
    /// `CodingKeys` níže), takže se nikdy nezapíše do UserDefaults plaintext.
    /// Persistenci řeší `SHServerRegistryStore` přes Keychain (`SHKeychain`);
    /// při načtení se hodnota dohydratuje, při uložení zapíše do Keychainu.
    /// Existující plaintext klíče z dřívějška se jednorázově zmigrují.
    var apiKey: String = ""

    /// `apiKey` je z Codable vynechán schválně — nesmí do UserDefaults. Ostatní
    /// pole se persistují normálně.
    enum CodingKeys: String, CodingKey {
        case id, name, baseURL
    }

    var normalizedBaseURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)
    }
}

struct SHPromptTemplate: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var content: String
}

struct SHAppConfig: Codable, Sendable {
    var inputFolder: String = ""
    var outputFolder: String = ""
    var cacheFolder: String = ""
    var promptFolder: String = ""
    var selectedServerID: UUID?
    var selectedInferenceModel: String = ""
    var selectedEmbeddingModel: String = ""
    var selectedRerankerModel: String = ""
    var selectedOCRModel: String = ""
    var ocrBackend: SHOCRBackend = .appleVision
    /// Default is SEARCH (per-document with RAG): for thinking/reasoning models
    /// (Qwen3, DeepSeek-R1) CONSOLIDATE spends minutes on prompt processing of
    /// the whole batch and then minutes more on chain-of-thought, while FAST
    /// wastes tokens by sending every document's full text. SEARCH packs only
    /// the top-k relevant chunks per document and runs the model concurrently
    /// per document, which in practice finishes faster and more reliably.
    var extractionMode: SHExtractionMode = .search
    var maxConcurrentInference: Int = 4
    var maxConcurrentPDFWorkers: Int = max(2, ProcessInfo.processInfo.processorCount / 2)
    var throttleDelayMs: Int = 50
    /// Context window of the loaded inference model, in tokens. Used for pre-flight
    /// checks in CONSOLIDATE mode so we don't waste a 10-minute inference on a
    /// request that the model will reject with "n_keep > n_ctx". 32 768 is a
    /// conservative default matching most local Llama/Qwen/Mistral builds.
    var modelContextTokens: Int = 32_768
    /// When true, the LLM output cache is ignored: every extraction re-runs
    /// inference even if an identical (prompt + docs + model) was cached. Useful
    /// when the model is non-deterministic and the user wants a fresh take.
    var bypassInferenceCache: Bool = false
    /// Per-request timeout for the LM Studio HTTP client, in seconds. Hits
    /// `URLSessionConfiguration.timeoutIntervalForRequest`. Short values detect
    /// stuck models quickly (KV cache fragmentation etc.), long values tolerate
    /// legitimately slow setups (CPU-only, large models). Default 600 s = 10 min.
    var requestTimeoutSeconds: Int = 600
    /// Average processing time per document from the most recent successful run,
    /// in milliseconds. Used as a baseline to produce a pre-run estimate so the
    /// user knows roughly how long the next batch will take. 0 means no history.
    var lastRunAvgDocumentMs: Double = 0
    /// Average per-page time from the most recent successful run (informative).
    var lastRunAvgPageMs: Double = 0
    /// Security-scoped bookmark data per folder path. Required so that sandboxed
    /// access to user-selected folders survives app restarts.
    var folderBookmarks: [String: Data] = [:]
    /// The prompt text currently being used for extraction. Persisted across app restarts
    /// so the user doesn't lose their work.
    var currentPrompt: String = ""
    /// Last file name (inside `promptFolder`) whose content was loaded into `currentPrompt`.
    /// Used only to show the active selection in the picker.
    var lastLoadedPromptName: String = ""
    /// Konverze office dokumentů (docx/odt/rtf/html/epub) přes pandoc. Default zapnuto.
    var officeConversionEnabled: Bool = true
    /// Extrakce textu z PDF přes `pdftotext -layout` místo PDFKit. Default vypnuto (opt-in).
    var popplerPDFTextEnabled: Bool = false
    /// Konverze tabulek (XLSX/XLS) na CSV přes csvkit (in2csv). Default zapnuto.
    var spreadsheetConversionEnabled: Bool = true
    /// Jazyky pro OCR backend ocrmypdf (tesseract), ve formátu `+`-spojených
    /// ISO 639-2 kódů, např. `ces+slk+deu+pol+eng`. Bundlovaná tessdata obsahují
    /// pouze ces/slk/deu/pol/eng — jiné jazyky vyžadují doplnit traineddata.
    var ocrLanguages: String = "ces+slk+deu+pol+eng"
    /// Timeout jednoho běhu ocrmypdf nad dokumentem, v sekundách. Skeny s mnoha
    /// stránkami mohou trvat dlouho; default 600 s = 10 min.
    var ocrTimeoutSeconds: Int = 600

    init() {}

    enum CodingKeys: String, CodingKey {
        case inputFolder, outputFolder, cacheFolder, promptFolder
        case selectedServerID, selectedInferenceModel, selectedEmbeddingModel
        case selectedRerankerModel, selectedOCRModel, ocrBackend
        case extractionMode, maxConcurrentInference, maxConcurrentPDFWorkers
        case throttleDelayMs, folderBookmarks, currentPrompt, lastLoadedPromptName
        case modelContextTokens, bypassInferenceCache, requestTimeoutSeconds
        case lastRunAvgDocumentMs, lastRunAvgPageMs
        case officeConversionEnabled, popplerPDFTextEnabled
        case spreadsheetConversionEnabled
        case ocrLanguages, ocrTimeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputFolder = try c.decodeIfPresent(String.self, forKey: .inputFolder) ?? ""
        outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder) ?? ""
        cacheFolder = try c.decodeIfPresent(String.self, forKey: .cacheFolder) ?? ""
        promptFolder = try c.decodeIfPresent(String.self, forKey: .promptFolder) ?? ""
        selectedServerID = try c.decodeIfPresent(UUID.self, forKey: .selectedServerID)
        selectedInferenceModel = try c.decodeIfPresent(String.self, forKey: .selectedInferenceModel) ?? ""
        selectedEmbeddingModel = try c.decodeIfPresent(String.self, forKey: .selectedEmbeddingModel) ?? ""
        selectedRerankerModel = try c.decodeIfPresent(String.self, forKey: .selectedRerankerModel) ?? ""
        selectedOCRModel = try c.decodeIfPresent(String.self, forKey: .selectedOCRModel) ?? ""
        ocrBackend = try c.decodeIfPresent(SHOCRBackend.self, forKey: .ocrBackend) ?? .appleVision
        extractionMode = try c.decodeIfPresent(SHExtractionMode.self, forKey: .extractionMode) ?? .search
        maxConcurrentInference = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentInference) ?? 4
        maxConcurrentPDFWorkers = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentPDFWorkers)
            ?? max(2, ProcessInfo.processInfo.processorCount / 2)
        throttleDelayMs = try c.decodeIfPresent(Int.self, forKey: .throttleDelayMs) ?? 50
        folderBookmarks = try c.decodeIfPresent([String: Data].self, forKey: .folderBookmarks) ?? [:]
        currentPrompt = try c.decodeIfPresent(String.self, forKey: .currentPrompt) ?? ""
        lastLoadedPromptName = try c.decodeIfPresent(String.self, forKey: .lastLoadedPromptName) ?? ""
        modelContextTokens = try c.decodeIfPresent(Int.self, forKey: .modelContextTokens) ?? 32_768
        bypassInferenceCache = try c.decodeIfPresent(Bool.self, forKey: .bypassInferenceCache) ?? false
        requestTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? 600
        lastRunAvgDocumentMs = try c.decodeIfPresent(Double.self, forKey: .lastRunAvgDocumentMs) ?? 0
        lastRunAvgPageMs = try c.decodeIfPresent(Double.self, forKey: .lastRunAvgPageMs) ?? 0
        officeConversionEnabled = try c.decodeIfPresent(Bool.self, forKey: .officeConversionEnabled) ?? true
        popplerPDFTextEnabled = try c.decodeIfPresent(Bool.self, forKey: .popplerPDFTextEnabled) ?? false
        spreadsheetConversionEnabled = try c.decodeIfPresent(Bool.self, forKey: .spreadsheetConversionEnabled) ?? true
        ocrLanguages = try c.decodeIfPresent(String.self, forKey: .ocrLanguages) ?? "ces+slk+deu+pol+eng"
        ocrTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .ocrTimeoutSeconds) ?? 600
    }
}
