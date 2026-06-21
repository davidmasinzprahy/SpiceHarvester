import Foundation
import Testing
@testable import SpiceHarvester

@Suite struct SHToolingTests {
    @Test func toolExecutableNamesAndVersionArgs() {
        #expect(SHTool.pandoc.executableName == "pandoc")
        #expect(SHTool.pdftotext.executableName == "pdftotext")
        #expect(SHTool.pdfinfo.executableName == "pdfinfo")
        #expect(SHTool.pandoc.versionArguments == ["--version"])
    }

    @Test func runtimeResolvesFromHelpersThenPath() throws {
        let fm = FileManager.default
        let helpers = fm.temporaryDirectory.appendingPathComponent("helpers-\(UUID().uuidString)")
        let pathDir = fm.temporaryDirectory.appendingPathComponent("path-\(UUID().uuidString)")
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        try fm.createDirectory(at: pathDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: helpers); try? fm.removeItem(at: pathDir) }

        // jen v PATH
        let inPath = pathDir.appendingPathComponent("pdfinfo")
        fm.createFile(atPath: inPath.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        // v helpers i PATH -> vyhrává helpers
        let inHelpers = helpers.appendingPathComponent("pandoc")
        fm.createFile(atPath: inHelpers.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let inPathPandoc = pathDir.appendingPathComponent("pandoc")
        fm.createFile(atPath: inPathPandoc.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let runtime = SHToolRuntime(helpersDirectory: helpers, pathDirectories: [pathDir])
        #expect(runtime.resolve(.pandoc)?.path == inHelpers.path)
        #expect(runtime.resolve(.pdfinfo)?.path == inPath.path)
        #expect(runtime.resolve(.pdftotext) == nil)
    }

    @Test func runtimeRunsPandocVersionWhenAvailable() async throws {
        let runtime = SHToolRuntime()
        guard runtime.resolve(.pandoc) != nil else { return } // přeskoč, není-li pandoc
        let result = try await runtime.run(.pandoc, arguments: ["--version"], timeout: 30)
        #expect(result.exitCode == 0)
        #expect(result.stdoutString.lowercased().contains("pandoc"))
    }

    @Test func parseVersionExtractsSemverFromOutput() {
        #expect(SHToolRegistry.parseVersion(from: "pandoc 3.1.9\nFeatures...") == "3.1.9")
        #expect(SHToolRegistry.parseVersion(from: "pdftotext version 24.04.0") == "24.04.0")
        #expect(SHToolRegistry.parseVersion(from: "no version here") == nil)
    }

    @Test func converterRoutingByExtension() {
        func route(_ name: String, poppler: Bool = false) -> SHDocumentConverter.Route {
            SHDocumentConverter.route(for: URL(fileURLWithPath: "/tmp/\(name)"), popplerPDFTextEnabled: poppler)
        }
        #expect(route("a.docx") == .pandoc)
        #expect(route("a.ODT") == .pandoc)
        #expect(route("a.epub") == .pandoc)
        #expect(route("a.pdf") == .native)                       // default: PDFKit
        #expect(route("a.pdf", poppler: true) == .popplerText)   // opt-in
        #expect(route("a.txt") == .native)
        #expect(route("a.csv") == .native)
    }

    @Test func converterPandocReadsHtmlWhenAvailable() async throws {
        let converter = SHDocumentConverter()
        guard converter.runtime.resolve(.pandoc) != nil else { return } // přeskoč

        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("doc-\(UUID().uuidString).html")
        try "<h1>Pacient</h1><p>Jan Novak</p>".write(to: url, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: url) }

        let result = try #require(await converter.convert(fileURL: url, popplerPDFTextEnabled: false))
        #expect(result.hasTextLayer == true)
        #expect(result.pageCount == 1)
        #expect(result.rawPages.first?.contains("Jan Novak") == true)
    }

    @Test func converterReturnsNilForNativeRoute() async throws {
        let converter = SHDocumentConverter()
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        #expect(await converter.convert(fileURL: url, popplerPDFTextEnabled: false) == nil)
    }

    @Test func scannerSupportsOfficeAndSpreadsheetExtensions() {
        let ext = SHFileScanService.supportedDocumentExtensions
        for e in ["docx", "odt", "rtf", "html", "htm", "epub", "xlsx", "xls"] {
            #expect(ext.contains(e), "chybí přípona \(e)")
        }
        // stávající nesmí zmizet
        #expect(ext.contains("pdf"))
        #expect(ext.contains("txt"))
    }

    @Test func appConfigToolingDefaultsAndCodableRoundtrip() throws {
        let config = SHAppConfig()
        #expect(config.officeConversionEnabled == true)
        #expect(config.popplerPDFTextEnabled == false)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SHAppConfig.self, from: data)
        #expect(decoded.officeConversionEnabled == true)
        #expect(decoded.popplerPDFTextEnabled == false)
    }

    @Test func in2csvToolNameAndVersionArgs() {
        #expect(SHTool.in2csv.executableName == "in2csv")
        #expect(SHTool.in2csv.versionArguments == ["--version"])
        #expect(SHTool.allCases.contains(.in2csv))
    }

    @Test func converterRoutesSpreadsheetsToCsvkit() {
        func route(_ name: String) -> SHDocumentConverter.Route {
            SHDocumentConverter.route(for: URL(fileURLWithPath: "/tmp/\(name)"), popplerPDFTextEnabled: false)
        }
        #expect(route("a.xlsx") == .csvkit)
        #expect(route("a.XLS") == .csvkit)
        #expect(route("a.csv") == .native)   // čisté CSV zůstává nativní
        #expect(route("a.docx") == .pandoc)  // beze změny
    }

    // Integrační test: vytvořit binární XLSX ze Swiftu je netriviální, proto se spustí
    // jen když existuje fixture na disku a in2csv je dostupný; jinak se přeskočí.
    @Test func converterConvertsXlsxWhenAvailable() async throws {
        let converter = SHDocumentConverter()
        guard converter.runtime.resolve(.in2csv) != nil else { return }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample.xlsx")
        guard FileManager.default.fileExists(atPath: fixture.path) else { return }

        let result = try #require(await converter.convert(fileURL: fixture, popplerPDFTextEnabled: false))
        #expect(result.hasTextLayer == true)
        #expect(result.pageCount == 1)
    }

    @Test func appConfigSpreadsheetDefaultAndRoundtrip() throws {
        let config = SHAppConfig()
        #expect(config.spreadsheetConversionEnabled == true)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SHAppConfig.self, from: data)
        #expect(decoded.spreadsheetConversionEnabled == true)
    }

    @Test func appConfigOCRSettingsDefaultsAndRoundtrip() throws {
        let config = SHAppConfig()
        #expect(config.ocrLanguages == "ces+slk+deu+pol+eng")
        #expect(config.ocrTimeoutSeconds == 600)

        // Ne-default hodnoty musí přežít encode→decode (custom decoder je musí číst).
        var custom = SHAppConfig()
        custom.ocrLanguages = "deu+eng"
        custom.ocrTimeoutSeconds = 900
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(SHAppConfig.self, from: data)
        #expect(decoded.ocrLanguages == "deu+eng")
        #expect(decoded.ocrTimeoutSeconds == 900)
    }

    @Test func pipelineUsesConverterThenFallsBackToNative() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString)")
        let cacheRoot = fm.temporaryDirectory.appendingPathComponent("conv-cache-\(UUID().uuidString)")
        let logRoot = fm.temporaryDirectory.appendingPathComponent("conv-log-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: logRoot, withIntermediateDirectories: true)
        defer { for u in [root, cacheRoot, logRoot] { try? fm.removeItem(at: u) } }

        // .txt jde nativní cestou (converter pro txt vrací nil)
        try "Pacient Jan".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let pipeline = SHPreprocessingPipeline(
            converter: SHDocumentConverter(),
            officeConversionEnabled: true,
            popplerPDFTextEnabled: false,
            ocrProvider: NoopOCRProvider(),
            cacheManager: SHCacheManager(cacheRoot: cacheRoot),
            logger: SHProcessingLogger(logFileURL: logRoot.appendingPathComponent("p.log")),
            benchmark: SHBenchmarkService(),
            maxConcurrentWorkers: 1
        )

        let output = await pipeline.run(inputFolder: root, onCounters: { _ in })
        let doc = try #require(output.cachedDocuments.first)
        #expect(doc.cleanedText.contains("Pacient Jan"))
        #expect(doc.metadata.hasTextLayer == true)
    }

    @Test func ocrToolNamesAndVersionArgs() {
        #expect(SHTool.ocrmypdf.executableName == "ocrmypdf")
        #expect(SHTool.tesseract.executableName == "tesseract")
        #expect(SHTool.ocrmypdf.versionArguments == ["--version"])
        #expect(SHTool.allCases.contains(.tesseract))
    }

    @Test func pipelineAcceptsSpreadsheetFlagAndKeepsNativeForText() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ss-\(UUID().uuidString)")
        let cacheRoot = fm.temporaryDirectory.appendingPathComponent("ss-cache-\(UUID().uuidString)")
        let logRoot = fm.temporaryDirectory.appendingPathComponent("ss-log-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: logRoot, withIntermediateDirectories: true)
        defer { for u in [root, cacheRoot, logRoot] { try? fm.removeItem(at: u) } }

        try "Pacient Jan".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let pipeline = SHPreprocessingPipeline(
            converter: SHDocumentConverter(),
            officeConversionEnabled: false,
            popplerPDFTextEnabled: false,
            spreadsheetConversionEnabled: true,
            ocrProvider: NoopOCRProvider(),
            cacheManager: SHCacheManager(cacheRoot: cacheRoot),
            logger: SHProcessingLogger(logFileURL: logRoot.appendingPathComponent("p.log")),
            benchmark: SHBenchmarkService(),
            maxConcurrentWorkers: 1
        )

        let output = await pipeline.run(inputFolder: root, onCounters: { _ in })
        let doc = try #require(output.cachedDocuments.first)
        #expect(doc.cleanedText.contains("Pacient Jan"))
    }

    @Test func ocrmypdfParsesSidecarPagesOnFormFeed() {
        let text = "Strana 1\u{0C}Strana 2\u{0C}Strana 3"
        let pages = SHOcrmypdfProvider.parseSidecarPages(text)
        #expect(pages.count == 3)
        #expect(pages[1] == "Strana 2")
    }

    @Test func ocrmypdfDropsTrailingEmptyPageFromTrailingFormFeed() {
        // ocrmypdf přidává form-feed i za poslední stránku → koncový prázdný prvek
        // se musí zahodit, jinak by spustil zbytečný fallback OCR.
        let pages = SHOcrmypdfProvider.parseSidecarPages("Strana 1\u{0C}Strana 2\u{0C}")
        #expect(pages == ["Strana 1", "Strana 2"])
    }

    @Test func ocrmypdfNormalizesLanguages() {
        // Prázdné/whitespace → default odpovídající bundlovaným tessdata.
        #expect(SHOcrmypdfProvider.normalizedLanguages("") == SHOcrmypdfProvider.defaultLanguages)
        #expect(SHOcrmypdfProvider.normalizedLanguages("   ") == SHOcrmypdfProvider.defaultLanguages)
        // Validní vstup se jen ořízne, jinak projde beze změny.
        #expect(SHOcrmypdfProvider.normalizedLanguages("  ces+eng  ") == "ces+eng")
        #expect(SHOcrmypdfProvider.normalizedLanguages("deu") == "deu")
    }

    @Test func ocrmypdfProviderReturnsEmptyWhenToolMissing() async throws {
        // runtime bez helpers i PATH -> resolve(.ocrmypdf) == nil
        let runtime = SHToolRuntime(helpersDirectory: nil, pathDirectories: [])
        let provider = SHOcrmypdfProvider(runtime: runtime)
        let pages = try await provider.extractText(from: URL(fileURLWithPath: "/tmp/none-\(UUID().uuidString).pdf"))
        #expect(pages.isEmpty)
    }

    @Test func ocrBackendOcrmypdfExposesTitleAndIsCodable() throws {
        #expect(SHOCRBackend.ocrmypdf.title == "ocrmypdf")
        #expect(SHOCRBackend.allCases.contains(.ocrmypdf))
        let data = try JSONEncoder().encode(SHOCRBackend.ocrmypdf)
        let decoded = try JSONDecoder().decode(SHOCRBackend.self, from: data)
        #expect(decoded == .ocrmypdf)
    }

    @Test func fallbackOCRUsesFallbackWhenPrimaryReturnsEmpty() async throws {
        struct EmptyOCR: SHOCRProviding {
            func extractText(from fileURL: URL) async throws -> [String] { [] }
        }
        struct TextOCR: SHOCRProviding {
            func extractText(from fileURL: URL) async throws -> [String] { ["text z Vision"] }
        }
        let provider = SHFallbackOCRProvider(primary: EmptyOCR(), fallback: TextOCR())
        let pages = try await provider.extractText(from: URL(fileURLWithPath: "/tmp/x-\(UUID().uuidString).pdf"))
        #expect(pages == ["text z Vision"])
    }
}
