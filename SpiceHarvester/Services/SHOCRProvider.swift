import Foundation
import AppKit
import PDFKit
import Vision

protocol SHOCRProviding: Sendable {
    func extractText(from fileURL: URL) async throws -> [String]
}

final class SHVisionOCRProvider: SHOCRProviding, Sendable {
    private let recognitionLanguages: [String]

    init(recognitionLanguages: [String] = ["cs-CZ", "sk-SK", "en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    /// Runs Vision OCR on every page of the PDF. Wrapped in a detached task so the
    /// synchronous `VNImageRequestHandler.perform` doesn't block whatever actor
    /// (typically the main actor or a pipeline worker) we're called from.
    /// Each page's work is inside an `autoreleasepool` – Core Foundation and
    /// Vision allocate heavily per page, and without draining the pool the peak
    /// memory footprint grows linearly with page count.
    func extractText(from fileURL: URL) async throws -> [String] {
        let languages = recognitionLanguages
        return try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: fileURL) else {
                return []
            }

            var pages: [String] = []
            pages.reserveCapacity(document.pageCount)

            for index in 0..<document.pageCount {
                try Task.checkCancellation()

                let text = autoreleasepool { () -> String in
                    guard let page = document.page(at: index),
                          let cgImage = SHPDFParser().renderPageImage(page) else {
                        return ""
                    }

                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.recognitionLanguages = languages
                    request.minimumTextHeight = 0.01

                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        return ""
                    }
                    let observations = request.results ?? []
                    return observations
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                }
                pages.append(text)
            }

            return pages
        }.value
    }
}

final class SHOpenAIVisionOCRProvider: SHOCRProviding, Sendable {
    private let client: SHOpenAICompatibleClient
    private let server: SHServerConfig
    private let model: String
    private let prompt: String
    private let parser = SHPDFParser()

    init(
        client: SHOpenAICompatibleClient,
        server: SHServerConfig,
        model: String,
        prompt: String = """
        Přepiš veškerý čitelný text z této stránky dokumentu do prostého textu.
        Zachovej pořadí, nadpisy, tabulky a důležité číselné hodnoty.
        Nevracej komentář, markdown ani vysvětlení; vrať pouze přepsaný text.
        """
    ) {
        self.client = client
        self.server = server
        self.model = model
        self.prompt = prompt
    }

    func extractText(from fileURL: URL) async throws -> [String] {
        guard let document = PDFDocument(url: fileURL) else {
            return []
        }

        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)

        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index),
                  let image = parser.renderPageImage(page, scale: 2.0),
                  let dataURL = Self.pngDataURL(from: image) else {
                pages.append("")
                continue
            }

            let text = try await client.visionText(
                server: server,
                model: model,
                prompt: prompt,
                imageDataURL: dataURL
            )
            pages.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return pages
    }

    private static func pngDataURL(from image: CGImage) -> String? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }
}

final class SHFallbackOCRProvider: SHOCRProviding, Sendable {
    private let primary: SHOCRProviding
    private let fallback: SHOCRProviding
    private let minimumUsableCharacters: Int

    init(primary: SHOCRProviding, fallback: SHOCRProviding, minimumUsableCharacters: Int = 8) {
        self.primary = primary
        self.fallback = fallback
        self.minimumUsableCharacters = minimumUsableCharacters
    }

    func extractText(from fileURL: URL) async throws -> [String] {
        let primaryPages = try await primary.extractText(from: fileURL)

        let needsFallback = primaryPages.contains { page in
            page.trimmingCharacters(in: .whitespacesAndNewlines).count < minimumUsableCharacters
        }
        guard needsFallback else {
            return primaryPages
        }

        let fallbackPages = try await fallback.extractText(from: fileURL)
        let pageCount = max(primaryPages.count, fallbackPages.count)
        return (0..<pageCount).map { index in
            let primaryText = primaryPages.indices.contains(index) ? primaryPages[index] : ""
            let trimmedPrimary = primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPrimary.count >= minimumUsableCharacters {
                return primaryText
            }
            return fallbackPages.indices.contains(index) ? fallbackPages[index] : primaryText
        }
    }
}
