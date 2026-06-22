import Foundation

/// Obsah jednoho projektu = to, co se serializuje do `.spiceharvester.json`
/// dokumentu (DocumentGroup). Per-document; runtime stav sem nepatří.
struct SHProjectContent: Codable, Sendable {
    var inputFolder: String = ""
    var outputFolder: String = ""
    var cacheFolder: String = ""
    var promptFolder: String = ""
    // Pozn.: security-scoped bookmarky složek se do projektu ZÁMĚRNĚ neukládají —
    // jsou machine-specific a dělaly by .spiceharvester.json nepřenositelný.
    // Přístup ke složkám drží app-level store (recentFolderBookmarks) / re-pick.
    var selectedServerID: UUID?
    var selectedInferenceModel: String = ""
    var selectedEmbeddingModel: String = ""
    var selectedRerankerModel: String = ""
    var selectedOCRModel: String = ""
    var extractionMode: SHExtractionMode = .search
    var currentPrompt: String = ""
    var lastLoadedPromptName: String = ""
    var promptHistory: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case inputFolder, outputFolder, cacheFolder, promptFolder
        case selectedServerID, selectedInferenceModel, selectedEmbeddingModel
        case selectedRerankerModel, selectedOCRModel, extractionMode
        case currentPrompt, lastLoadedPromptName, promptHistory
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
        extractionMode = try c.decodeIfPresent(SHExtractionMode.self, forKey: .extractionMode) ?? .search
        currentPrompt = try c.decodeIfPresent(String.self, forKey: .currentPrompt) ?? ""
        lastLoadedPromptName = try c.decodeIfPresent(String.self, forKey: .lastLoadedPromptName) ?? ""
        promptHistory = try c.decodeIfPresent([String].self, forKey: .promptHistory) ?? []
    }
}

/// App-level předvolby (Settings, Cmd+,) — sdílené přes všechny projekty.
/// Přesun z `SHAppConfig` (rozhodnutí A).
struct SHAppPreferences: Codable, Sendable {
    var maxConcurrentInference: Int = 4
    var maxConcurrentPDFWorkers: Int = max(2, ProcessInfo.processInfo.processorCount / 2)
    var throttleDelayMs: Int = 50
    var modelContextTokens: Int = 32_768
    var requestTimeoutSeconds: Int = 600
    var bypassInferenceCache: Bool = false
    var ocrBackend: SHOCRBackend = .appleVision
    var ocrLanguages: String = "ces+slk+deu+pol+eng"
    var ocrTimeoutSeconds: Int = 600
    var officeConversionEnabled: Bool = true
    var popplerPDFTextEnabled: Bool = false
    var spreadsheetConversionEnabled: Bool = true
    var lastRunAvgDocumentMs: Double = 0
    var lastRunAvgPageMs: Double = 0

    init() {}

    enum CodingKeys: String, CodingKey {
        case maxConcurrentInference, maxConcurrentPDFWorkers, throttleDelayMs
        case modelContextTokens, requestTimeoutSeconds, bypassInferenceCache
        case ocrBackend, ocrLanguages, ocrTimeoutSeconds
        case officeConversionEnabled, popplerPDFTextEnabled, spreadsheetConversionEnabled
        case lastRunAvgDocumentMs, lastRunAvgPageMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxConcurrentInference = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentInference) ?? 4
        maxConcurrentPDFWorkers = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentPDFWorkers)
            ?? max(2, ProcessInfo.processInfo.processorCount / 2)
        throttleDelayMs = try c.decodeIfPresent(Int.self, forKey: .throttleDelayMs) ?? 50
        modelContextTokens = try c.decodeIfPresent(Int.self, forKey: .modelContextTokens) ?? 32_768
        requestTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? 600
        bypassInferenceCache = try c.decodeIfPresent(Bool.self, forKey: .bypassInferenceCache) ?? false
        ocrBackend = try c.decodeIfPresent(SHOCRBackend.self, forKey: .ocrBackend) ?? .appleVision
        ocrLanguages = try c.decodeIfPresent(String.self, forKey: .ocrLanguages) ?? "ces+slk+deu+pol+eng"
        ocrTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .ocrTimeoutSeconds) ?? 600
        officeConversionEnabled = try c.decodeIfPresent(Bool.self, forKey: .officeConversionEnabled) ?? true
        popplerPDFTextEnabled = try c.decodeIfPresent(Bool.self, forKey: .popplerPDFTextEnabled) ?? false
        spreadsheetConversionEnabled = try c.decodeIfPresent(Bool.self, forKey: .spreadsheetConversionEnabled) ?? true
        lastRunAvgDocumentMs = try c.decodeIfPresent(Double.self, forKey: .lastRunAvgDocumentMs) ?? 0
        lastRunAvgPageMs = try c.decodeIfPresent(Double.self, forKey: .lastRunAvgPageMs) ?? 0
    }
}
