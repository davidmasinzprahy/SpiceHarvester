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

    /// Rozparsuje výstup `tesseract --list-langs` na množinu dostupných kódů.
    /// Hlavičkový řádek („List of available languages…") i víceslovné řádky se
    /// ignorují. Funguje na stdout i stderr (tesseract list rozhazuje mezi oba).
    static func parseAvailableLanguages(from output: String) -> Set<String> {
        var langs = Set<String>()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.lowercased().hasPrefix("list of available languages") { continue }
            if line.contains(" ") { continue }
            langs.insert(line)
        }
        return langs
    }

    /// Kódy z uživatelského `+`-vstupu, které nejsou mezi dostupnými jazyky.
    /// Když dostupné nejsou známé (prázdná množina, např. tesseract chybí),
    /// vrací prázdno — nehlásíme falešné poplachy.
    static func unsupportedLanguages(in input: String, available: Set<String>) -> [String] {
        guard !available.isEmpty else { return [] }
        let codes = input
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return codes.filter { !available.contains($0) }
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
