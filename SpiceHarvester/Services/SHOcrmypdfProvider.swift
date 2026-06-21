import Foundation

/// OCR skenovaných PDF přes lokální ocrmypdf (tesseract + ghostscript).
/// Spouští `ocrmypdf --sidecar`, vrací text po stránkách. Chybějící nástroj
/// nebo chyba => prázdné pole (řetězec SHFallbackOCRProvider sáhne po Vision).
final class SHOcrmypdfProvider: SHOCRProviding, Sendable {
    private let runtime: SHToolRuntime
    private let languages: String
    private let timeout: TimeInterval

    init(runtime: SHToolRuntime = SHToolRuntime(),
         languages: String = "ces+slk+deu+pol+eng",
         timeout: TimeInterval = 600) {
        self.runtime = runtime
        self.languages = Self.normalizedLanguages(languages)
        self.timeout = timeout
    }

    /// Default jazyky odpovídající bundlovaným tessdata.
    static let defaultLanguages = "ces+slk+deu+pol+eng"

    /// Prázdné/whitespace jazyky by ocrmypdf odmítl; spadni na default.
    static func normalizedLanguages(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultLanguages : trimmed
    }

    func extractText(from fileURL: URL) async throws -> [String] {
        guard runtime.resolve(.ocrmypdf) != nil else { return [] }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("ocrmypdf-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let outputPDF = workDir.appendingPathComponent("out.pdf")
        let sidecar = workDir.appendingPathComponent("sidecar.txt")

        // --force-ocr: skeny rasterizuj a vždy OCRuj (vstup nemá použitelnou textovou vrstvu).
        let args = ["-l", languages, "--force-ocr", "--sidecar", sidecar.path, fileURL.path, outputPDF.path]
        guard let result = try? await runtime.run(.ocrmypdf, arguments: args, timeout: timeout),
              result.exitCode == 0,
              let text = try? String(contentsOf: sidecar, encoding: .utf8) else {
            return []
        }
        return Self.parseSidecarPages(text)
    }

    /// Čistá funkce: sidecar text dělí na stránky podle form-feed `\u{0C}`.
    /// ocrmypdf přidává form-feed za každou stránku, takže poslední prvek po splitu
    /// je prázdný; zahodíme ho, jinak prázdná „stránka" zbytečně spustí fallback OCR.
    static func parseSidecarPages(_ text: String) -> [String] {
        var pages = text.components(separatedBy: "\u{0C}")
        if pages.last?.isEmpty == true { pages.removeLast() }
        return pages
    }
}
