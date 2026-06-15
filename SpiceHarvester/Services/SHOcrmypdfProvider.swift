import Foundation

/// OCR skenovaných PDF přes lokální ocrmypdf (tesseract + ghostscript).
/// Spouští `ocrmypdf --sidecar`, vrací text po stránkách. Chybějící nástroj
/// nebo chyba => prázdné pole (řetězec SHFallbackOCRProvider sáhne po Vision).
final class SHOcrmypdfProvider: SHOCRProviding, Sendable {
    private let runtime: SHToolRuntime
    private let languages: String

    init(runtime: SHToolRuntime = SHToolRuntime(), languages: String = "ces+slk+deu+pol+eng") {
        self.runtime = runtime
        self.languages = languages
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
        guard let result = try? await runtime.run(.ocrmypdf, arguments: args, timeout: 600),
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
