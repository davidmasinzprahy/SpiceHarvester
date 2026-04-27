import Foundation

protocol ExtractionServicing {
    func detectLanguage(for text: String) -> String
    func extractText(from path: String) -> String
    func extractText(from path: String, ocrResolutionWidth: CGFloat) -> String
    func extractPageImages(from path: String, resolutionWidth: CGFloat) -> [Data]
    func prefetchPDFText(paths: [String])
    func extractStructuredChunks(from path: String, maxChunkCharacters: Int) -> [String]?
}

extension ExtractionServicing {
    func prefetchPDFText(paths: [String]) {}
    func extractStructuredChunks(from path: String, maxChunkCharacters: Int) -> [String]? { nil }
}

protocol AnalysisServicing {
    func sendSinglePrompt(
        promptText: String,
        modelName: String
    ) async throws -> (response: String, duration: TimeInterval)

    func analyzeChunkWithRetry(
        chunk: String,
        promptText: String,
        modelName: String,
        minimumChunkSize: Int
    ) async throws -> (responses: [String], duration: TimeInterval)

    func summarizeWithRetry(
        summaries: [String],
        template: String,
        modelName: String,
        initialCharacterLimit: Int
    ) async throws -> (summary: String, duration: TimeInterval)

    func analyzeWithVision(
        images: [Data],
        promptText: String,
        modelName: String
    ) async throws -> (response: String, duration: TimeInterval)
}

protocol EmbeddingServicing {
    func embed(texts: [String], modelName: String) async throws -> [[Float]]
}
