import Foundation

struct SHDocumentConverter: Sendable {
    enum Route: Sendable, Equatable {
        case native        // txt/md/csv/tsv/json/pdf-default -> stávající cesta
        case pandoc        // office dokumenty
        case popplerText   // pdf s textovou vrstvou, opt-in
    }

    /// Office formáty řešené pandocem.
    static let pandocExtensions: Set<String> = ["docx", "odt", "rtf", "html", "htm", "epub"]

    let runtime: SHToolRuntime

    init(runtime: SHToolRuntime = SHToolRuntime()) {
        self.runtime = runtime
    }

    /// Čisté rozhodnutí, jaký nástroj (pokud vůbec) na soubor použít.
    static func route(for fileURL: URL, popplerPDFTextEnabled: Bool) -> Route {
        let ext = fileURL.pathExtension.lowercased()
        if pandocExtensions.contains(ext) { return .pandoc }
        if ext == "pdf", popplerPDFTextEnabled { return .popplerText }
        return .native
    }
}
