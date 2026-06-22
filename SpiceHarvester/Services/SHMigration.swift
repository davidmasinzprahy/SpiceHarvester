import Foundation

/// Rozdělení legacy `SHAppConfig` na obsah dokumentu + app prefs (rozhodnutí A).
/// Čistá funkce — testovatelná bez IO. Zapojení při startu je ve Fázi 6.
enum SHMigration {
    struct Split { let content: SHProjectContent; let prefs: SHAppPreferences }

    static func split(_ c: SHAppConfig) -> Split {
        var content = SHProjectContent()
        content.inputFolder = c.inputFolder
        content.outputFolder = c.outputFolder
        content.cacheFolder = c.cacheFolder
        content.promptFolder = c.promptFolder
        content.folderBookmarks = c.folderBookmarks
        content.selectedServerID = c.selectedServerID
        content.selectedInferenceModel = c.selectedInferenceModel
        content.selectedEmbeddingModel = c.selectedEmbeddingModel
        content.selectedRerankerModel = c.selectedRerankerModel
        content.selectedOCRModel = c.selectedOCRModel
        content.extractionMode = c.extractionMode
        content.currentPrompt = c.currentPrompt
        content.lastLoadedPromptName = c.lastLoadedPromptName

        var prefs = SHAppPreferences()
        prefs.maxConcurrentInference = c.maxConcurrentInference
        prefs.maxConcurrentPDFWorkers = c.maxConcurrentPDFWorkers
        prefs.throttleDelayMs = c.throttleDelayMs
        prefs.modelContextTokens = c.modelContextTokens
        prefs.requestTimeoutSeconds = c.requestTimeoutSeconds
        prefs.bypassInferenceCache = c.bypassInferenceCache
        prefs.ocrBackend = c.ocrBackend
        prefs.ocrLanguages = c.ocrLanguages
        prefs.ocrTimeoutSeconds = c.ocrTimeoutSeconds
        prefs.officeConversionEnabled = c.officeConversionEnabled
        prefs.popplerPDFTextEnabled = c.popplerPDFTextEnabled
        prefs.spreadsheetConversionEnabled = c.spreadsheetConversionEnabled
        prefs.lastRunAvgDocumentMs = c.lastRunAvgDocumentMs
        prefs.lastRunAvgPageMs = c.lastRunAvgPageMs
        return Split(content: content, prefs: prefs)
    }
}
