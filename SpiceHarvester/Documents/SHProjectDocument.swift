import SwiftUI
import Combine
import UniformTypeIdentifiers

extension UTType {
    /// Projektový dokument Spice Harvester (`*.spiceharvester.json`). Napojeno na
    /// existující exported UTI z `Info.plist` (varianta B Finder-open).
    static let spiceHarvesterProject = UTType(exportedAs: "DavidMasin.SpiceHarvester.project")
}

/// Document-based obsah projektu pro `DocumentGroup`. `ReferenceFileDocument`
/// (ne `FileDocument`), protože obsah je sdílený s běhovým `SHDocumentViewModel`
/// a model je referenční. DocumentGroup zajišťuje autosave / verze / „modified"
/// tečku / Cmd+S.
final class SHProjectDocument: ReferenceFileDocument {
    typealias Snapshot = SHProjectContent

    static var readableContentTypes: [UTType] { [.spiceHarvesterProject] }
    static var writableContentTypes: [UTType] { [.spiceHarvesterProject] }

    @Published var content: SHProjectContent

    init(content: SHProjectContent = SHProjectContent()) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            self.content = SHProjectContent()
            return
        }
        // Tolerantní decode — neúplný/cizí JSON spadne na prázdný obsah,
        // ať se okno otevře místo tvrdé chyby.
        self.content = (try? SHJSON.decoder().decode(SHProjectContent.self, from: data)) ?? SHProjectContent()
    }

    func snapshot(contentType: UTType) throws -> SHProjectContent { content }

    func fileWrapper(snapshot: SHProjectContent, configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try SHJSON.encoder().encode(snapshot)
        return FileWrapper(regularFileWithContents: data)
    }
}
