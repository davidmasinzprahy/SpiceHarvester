import Foundation

struct SHDocumentConverter: Sendable {
    enum Route: Sendable, Equatable {
        case native        // txt/md/csv/tsv/json/pdf-default -> stávající cesta
        case pandoc        // office dokumenty
        case popplerText   // pdf s textovou vrstvou, opt-in
        case csvkit       // tabulky (xlsx/xls) -> CSV přes in2csv
    }

    /// Office formáty řešené pandocem.
    static let pandocExtensions: Set<String> = ["docx", "odt", "rtf", "html", "htm", "epub"]

    /// Tabulkové formáty řešené csvkit (in2csv).
    static let csvkitExtensions: Set<String> = ["xlsx", "xls"]

    let runtime: SHToolRuntime

    init(runtime: SHToolRuntime = SHToolRuntime()) {
        self.runtime = runtime
    }

    /// Čisté rozhodnutí, jaký nástroj (pokud vůbec) na soubor použít.
    static func route(for fileURL: URL, popplerPDFTextEnabled: Bool) -> Route {
        let ext = fileURL.pathExtension.lowercased()
        if csvkitExtensions.contains(ext) { return .csvkit }
        if pandocExtensions.contains(ext) { return .pandoc }
        if ext == "pdf", popplerPDFTextEnabled { return .popplerText }
        return .native
    }

    /// Vrátí normalizovaný výsledek, nebo `nil` pro nativní cestu / při chybějícím nástroji.
    func convert(fileURL: URL, popplerPDFTextEnabled: Bool) async -> SHPDFParseResult? {
        switch Self.route(for: fileURL, popplerPDFTextEnabled: popplerPDFTextEnabled) {
        case .native:
            return nil
        case .pandoc:
            return await runPandoc(fileURL)
        case .popplerText:
            return await runPdftotext(fileURL)
        case .csvkit:
            return await runIn2csv(fileURL)
        }
    }

    private func runPandoc(_ fileURL: URL) async -> SHPDFParseResult? {
        guard runtime.resolve(.pandoc) != nil else { return nil }
        guard let result = try? await runtime.run(.pandoc, arguments: ["-t", "plain", fileURL.path], timeout: 120),
              result.exitCode == 0 else { return nil }
        let text = result.stdoutString
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHPDFParseResult(rawPages: [text], hasTextLayer: !trimmed.isEmpty, pageCount: 1)
    }

    private func runIn2csv(_ fileURL: URL) async -> SHPDFParseResult? {
        guard runtime.resolve(.in2csv) != nil else { return nil }
        // in2csv detekuje formát podle přípony a píše CSV na stdout
        guard let result = try? await runtime.run(.in2csv, arguments: [fileURL.path], timeout: 120),
              result.exitCode == 0 else { return nil }
        let text = result.stdoutString
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHPDFParseResult(rawPages: [text], hasTextLayer: !trimmed.isEmpty, pageCount: 1)
    }

    private func runPdftotext(_ fileURL: URL) async -> SHPDFParseResult? {
        guard runtime.resolve(.pdftotext) != nil else { return nil }
        // `-layout` zachová sloupce; `-` posílá výstup na stdout
        guard let result = try? await runtime.run(.pdftotext, arguments: ["-layout", fileURL.path, "-"], timeout: 120),
              result.exitCode == 0 else { return nil }
        let pages = result.stdoutString.components(separatedBy: "\u{0C}")
        let nonEmpty = pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return SHPDFParseResult(rawPages: pages, hasTextLayer: nonEmpty, pageCount: pages.count)
    }
}
