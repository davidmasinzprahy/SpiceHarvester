import Foundation
import Testing
@testable import SpiceHarvester

/// `.serialized` because several tests below mutate
/// `UserDefaults.standard` under shared keys
/// (`SHRecentProjects`, `SHProjectBookmarks`). Swift Testing
/// parallelizes by default; without serialization the
/// `defer { restore }` save/restore dance races between tests and
/// produces sporadic failures on busy CI.
///
/// `init()` resets process-wide static state on
/// `SHDocumentViewModel` (live-vm registry + active output-folder
/// claims) so a previous test's vm doesn't bleed into the
/// `resolveIntentTarget` lookup or the collision check the next
/// test exercises. Swift Testing constructs a new suite instance
/// per `@Test`, so this runs once before each test.
@Suite(.serialized)
struct SpiceHarvesterTests {
    init() async {
        await MainActor.run {
            SHDocumentViewModel._resetStaticStateForTesting()
        }
    }

    @Test func extractionResultMergeFillsOnlyMissingFields() {
        var base = SHExtractionResult.empty(sourceFile: "a.pdf")
        base.patient_name = "Jan Novak"
        base.confidence = 0.8

        var partial = SHExtractionResult.empty(sourceFile: "a.pdf")
        partial.patient_name = "Jiny"
        partial.patient_id = "850101/1234"
        partial.diagnoses = ["I10"]
        partial.confidence = 0.6

        base.merge(with: partial)

        #expect(base.patient_name == "Jan Novak")
        #expect(base.patient_id == "850101/1234")
        #expect(base.diagnoses == ["I10"])
        #expect(abs(base.confidence - 0.7) < 0.0001)
    }

    @Test func schemaValidatorAcceptsValidJSON() throws {
        let json = """
        {
          "source_file": "a.pdf",
          "patient_name": "Jan Novak",
          "patient_id": "850101/1234",
          "birth_date": "1985-01-01",
          "admission_date": "2026-01-03",
          "discharge_date": "2026-01-08",
          "diagnoses": ["I10"],
          "medication": ["Prestarium"],
          "lab_values": ["CRP 4"],
          "discharge_status": "stabilizovan",
          "warnings": [],
          "confidence": 0.91
        }
        """

        let decoded = try SHResultSchemaValidator().decodeValidated(json: json)
        #expect(decoded.patient_name == "Jan Novak")
        #expect(decoded.confidence > 0.9)
    }

    @Test func schemaValidatorRejectsMissingField() {
        let invalid = """
        {
          "source_file": "a.pdf",
          "patient_name": "Jan Novak",
          "patient_id": "850101/1234",
          "birth_date": "1985-01-01",
          "admission_date": "2026-01-03",
          "discharge_date": "2026-01-08",
          "diagnoses": [],
          "medication": [],
          "lab_values": [],
          "warnings": [],
          "confidence": 0.4
        }
        """

        #expect(throws: Error.self) {
            try SHResultSchemaValidator().decodeValidated(json: invalid)
        }
    }

    @Test func cacheManagerSaveLoadAndClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spice-cache-test-\(UUID().uuidString)")
        let cache = SHCacheManager(cacheRoot: root)

        let doc = SHCachedDocument(
            sourceFile: "/tmp/a.pdf",
            fileHash: "abc",
            processedAt: Date(),
            rawText: "raw",
            cleanedText: "clean",
            pages: [SHDocumentPage(pageIndex: 0, rawText: "raw", cleanedText: "clean")],
            metadata: SHDocumentMetadata(pageCount: 1, usedOCR: false, hasTextLayer: true)
        )

        await cache.save(doc)
        let loaded = await cache.load(hash: "abc")
        #expect(loaded?.cleanedText == "clean")
        #expect(await cache.count() == 1)

        await cache.clear()
        #expect(await cache.count() == 0)
    }

    @Test func inferenceCacheKeyInvalidatesOnSemanticInputs() {
        let base = SHInferenceCache.makeKey(
            systemPrompt: "system",
            prompt: "prompt",
            cleanerVersion: "cleaner-v1",
            documentHashes: ["b", "a"],
            model: "model-a",
            embeddingModel: "",
            rerankerModel: "",
            modeTag: "fast"
        )

        let sameWithDifferentDocumentOrder = SHInferenceCache.makeKey(
            systemPrompt: "system",
            prompt: "prompt",
            cleanerVersion: "cleaner-v1",
            documentHashes: ["a", "b"],
            model: "model-a",
            embeddingModel: "",
            rerankerModel: "",
            modeTag: "fast"
        )
        #expect(base == sameWithDifferentDocumentOrder)

        let changedPrompt = SHInferenceCache.makeKey(
            systemPrompt: "system",
            prompt: "prompt changed",
            cleanerVersion: "cleaner-v1",
            documentHashes: ["a", "b"],
            model: "model-a",
            embeddingModel: "",
            rerankerModel: "",
            modeTag: "fast"
        )
        let changedModel = SHInferenceCache.makeKey(
            systemPrompt: "system",
            prompt: "prompt",
            cleanerVersion: "cleaner-v1",
            documentHashes: ["a", "b"],
            model: "model-b",
            embeddingModel: "",
            rerankerModel: "",
            modeTag: "fast"
        )
        let changedMode = SHInferenceCache.makeKey(
            systemPrompt: "system",
            prompt: "prompt",
            cleanerVersion: "cleaner-v1",
            documentHashes: ["a", "b"],
            model: "model-a",
            embeddingModel: "",
            rerankerModel: "",
            modeTag: "search"
        )
        let changedCleaner = SHInferenceCache.makeKey(
            systemPrompt: "system",
            prompt: "prompt",
            cleanerVersion: "cleaner-v2",
            documentHashes: ["a", "b"],
            model: "model-a",
            embeddingModel: "",
            rerankerModel: "",
            modeTag: "fast"
        )
        let changedDocument = SHInferenceCache.makeKey(
            systemPrompt: "system",
            prompt: "prompt",
            cleanerVersion: "cleaner-v1",
            documentHashes: ["a", "c"],
            model: "model-a",
            embeddingModel: "",
            rerankerModel: "",
            modeTag: "fast"
        )

        #expect(base != changedPrompt)
        #expect(base != changedModel)
        #expect(base != changedMode)
        #expect(base != changedCleaner)
        #expect(base != changedDocument)
    }

    @Test func fileScannerFindsSupportedDocumentsAndSkipsHiddenOrUnsupportedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spice-scan-test-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let supported = [
            root.appendingPathComponent("a.pdf"),
            root.appendingPathComponent("b.txt"),
            nested.appendingPathComponent("c.md"),
            nested.appendingPathComponent("d.csv"),
            nested.appendingPathComponent("e.json")
        ]
        for url in supported {
            try "test".write(to: url, atomically: true, encoding: .utf8)
        }
        try "ignore".write(to: root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
        try "hidden".write(to: root.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)

        let scanner = SHFileScanService()
        let documents = scanner.recursiveDocuments(in: root).map(\.lastPathComponent)
        let pdfs = scanner.recursivePDFs(in: root).map(\.lastPathComponent)

        #expect(documents == ["a.pdf", "b.txt", "c.md", "d.csv", "e.json"])
        #expect(pdfs == ["a.pdf"])
    }

    @Test func preprocessingPipelineReadsPlainTextDocumentsWithoutOCR() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spice-preprocess-test-\(UUID().uuidString)")
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("spice-preprocess-cache-\(UUID().uuidString)")
        let logRoot = FileManager.default.temporaryDirectory.appendingPathComponent("spice-preprocess-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: logRoot)
        }

        let textURL = root.appendingPathComponent("report.txt")
        try "Pacient: Jan Novak\nCRP: 4 mg/l\n".write(to: textURL, atomically: true, encoding: .utf8)

        let pipeline = SHPreprocessingPipeline(
            ocrProvider: NoopOCRProvider(),
            cacheManager: SHCacheManager(cacheRoot: cacheRoot),
            logger: SHProcessingLogger(logFileURL: logRoot.appendingPathComponent("processing.log")),
            benchmark: SHBenchmarkService(),
            maxConcurrentWorkers: 1
        )

        let output = await pipeline.run(inputFolder: root, onCounters: { _ in })

        #expect(output.cachedDocuments.count == 1)
        let doc = try #require(output.cachedDocuments.first)
        #expect(URL(fileURLWithPath: doc.sourceFile).standardizedFileURL.path == textURL.standardizedFileURL.path)
        #expect(doc.cleanedText.contains("Pacient: Jan Novak"))
        #expect(doc.metadata.pageCount == 1)
        #expect(doc.metadata.usedOCR == false)
        #expect(doc.metadata.hasTextLayer == true)
    }

    @Test func csvExportCreatesOneRowPerDocument() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("spice-export-test-\(UUID().uuidString)")
        let exporter = SHExportService()

        let results = [
            SHExtractionResult(
                source_file: "/tmp/a.pdf",
                patient_name: "A",
                patient_id: "1",
                birth_date: "",
                admission_date: "",
                discharge_date: "",
                diagnoses: [],
                medication: [],
                lab_values: [],
                discharge_status: "",
                warnings: [],
                confidence: 0.5
            ),
            SHExtractionResult(
                source_file: "/tmp/b.pdf",
                patient_name: "B",
                patient_id: "2",
                birth_date: "",
                admission_date: "",
                discharge_date: "",
                diagnoses: [],
                medication: [],
                lab_values: [],
                discharge_status: "",
                warnings: [],
                confidence: 0.6
            )
        ]

        try exporter.exportAll(results: results, outputFolder: out)

        let csvURL = out.appendingPathComponent("results.csv")
        let data = try Data(contentsOf: csvURL)
        #expect(data.starts(with: Data([0xEF, 0xBB, 0xBF])))
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = csv.split(separator: "\n")

        #expect(lines.count == 3) // header + 2 dokumenty
    }

    @Test func exportPreservesRawResponsesAsSeparateFiles() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("spice-raw-export-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }

        let results = [
            SHExtractionResult(
                source_file: "/tmp/a.pdf",
                patient_name: "A",
                patient_id: "1",
                birth_date: "",
                admission_date: "",
                discharge_date: "",
                diagnoses: [],
                medication: [],
                lab_values: [],
                discharge_status: "",
                warnings: [],
                confidence: 0.5,
                rawResponse: #"{"custom": "schema"}"#
            ),
            SHExtractionResult(
                source_file: "/tmp/b.pdf",
                patient_name: "B",
                patient_id: "2",
                birth_date: "",
                admission_date: "",
                discharge_date: "",
                diagnoses: [],
                medication: [],
                lab_values: [],
                discharge_status: "",
                warnings: [],
                confidence: 0.6,
                rawResponse: "plain model output"
            )
        ]

        try SHExportService().exportAll(results: results, outputFolder: out)

        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("a_raw.json").path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("b_raw.txt").path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("raw_responses.json").path))
        let rawText = try String(contentsOf: out.appendingPathComponent("b_raw.txt"), encoding: .utf8)
        #expect(rawText == "plain model output")
    }

    @Test func extractionModesExposeExpectedTitlesAndDefault() {
        #expect(SHExtractionMode.fast.title == "FAST")
        #expect(SHExtractionMode.search.title == "SEARCH")
        #expect(SHExtractionMode.consolidate.title == "CONSOLIDATE")
        #expect(SHAppConfig().extractionMode == .search)
    }

    @Test func readmeDoesNotRegressKnownDocumentationFacts() throws {
        let readme = try String(contentsOf: repositoryRoot().appendingPathComponent("README.md"), encoding: .utf8)

        #expect(readme.contains("macOS 15.6+"))
        #expect(readme.contains("Výchozí režim aplikace je **SEARCH**."))
        #expect(readme.contains("PDF soubory nebo jinými typy souborů"))
        #expect(readme.contains("SPARK DGX"))
        #expect(!readme.contains("macOS 14+"))
        #expect(!readme.contains("Výchozí režim je **FAST**"))
        #expect(!readme.contains("SPAR DGX"))
    }

    @Test func repositoryContributorMetadataDoesNotMentionExternalCoauthors() throws {
        let root = repositoryRoot()
        let forbidden = [
            "Cl" + "aude",
            "Co-" + "Authored-By: " + "Cl" + "aude",
            "noreply@" + "anthropic.com"
        ]
        let files = [
            root.appendingPathComponent("README.md"),
            root.appendingPathComponent(".gitignore")
        ]

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in forbidden {
                #expect(!text.localizedCaseInsensitiveContains(needle))
            }
        }
    }

    @Test func textCleanerRemovesRepeatedHeaderFooterCaseInsensitive() {
        let cleaner = SHTextCleaningService()
        let pages = [
            "FAKULTNI NEMOCNICE\nPacient Jan\nStrana 1/2",
            "fakultni nemocnice\nPacient Petr\nstrana 2/2"
        ]

        let cleaned = cleaner.cleanPages(pages)
        #expect(cleaned.count == 2)
        #expect(cleaned[0].cleanedText.contains("Pacient Jan"))
        #expect(cleaned[1].cleanedText.contains("Pacient Petr"))
        #expect(!cleaned[0].cleanedText.lowercased().contains("fakultni nemocnice"))
        #expect(!cleaned[1].cleanedText.lowercased().contains("fakultni nemocnice"))
    }

    // MARK: – Recent projects persistence + cross-window sync

    /// Verifies the init-side restore: a path written to the shared
    /// `SHRecentProjects` UserDefaults key under a previous launch must
    /// re-appear in `recentProjectURLs` on the next vm construction.
    /// Without this roundtrip working, `Otevřít nedávné…` would be
    /// empty after every app restart.
    @MainActor
    @Test func recentProjectURLsRestoredFromUserDefaultsOnInit() async {
        let recentKey = "SHRecentProjects"
        let bookmarksKey = "SHProjectBookmarks"
        let priorPaths = UserDefaults.standard.object(forKey: recentKey)
        let priorBookmarks = UserDefaults.standard.object(forKey: bookmarksKey)
        defer {
            UserDefaults.standard.set(priorPaths, forKey: recentKey)
            UserDefaults.standard.set(priorBookmarks, forKey: bookmarksKey)
        }

        let projectPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh-roundtrip-\(UUID().uuidString).spiceharvester.json")
            .path
        UserDefaults.standard.set([projectPath], forKey: recentKey)
        UserDefaults.standard.removeObject(forKey: bookmarksKey)

        let vm = SHDocumentViewModel(persistenceMode: .scratch)

        #expect(vm.recentProjectURLs.map(\.path) == [projectPath])
    }

    /// `openProject(at:)` called with a path that exists but isn't a
    /// valid project JSON must drop the URL from the recents list. The
    /// menu otherwise keeps listing the dead entry and the user gets
    /// the same error on every click.
    @MainActor
    @Test func openProjectForgetsURLWhenJSONInvalid() async throws {
        let recentKey = "SHRecentProjects"
        let bookmarksKey = "SHProjectBookmarks"
        let priorPaths = UserDefaults.standard.object(forKey: recentKey)
        let priorBookmarks = UserDefaults.standard.object(forKey: bookmarksKey)
        defer {
            UserDefaults.standard.set(priorPaths, forKey: recentKey)
            UserDefaults.standard.set(priorBookmarks, forKey: bookmarksKey)
        }

        // Write non-project JSON to a temp file. The sniff in
        // openProject(at:) checks for `schemaVersion` and rejects this
        // payload as "not a project" rather than letting the Codable
        // decoder spit out a keyNotFound error.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh-bad-\(UUID().uuidString).spiceharvester.json")
        try "{\"foo\": 1}".data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        UserDefaults.standard.set([url.path], forKey: recentKey)
        UserDefaults.standard.removeObject(forKey: bookmarksKey)

        let vm = SHDocumentViewModel(persistenceMode: .scratch)
        #expect(vm.recentProjectURLs.map(\.path) == [url.path])

        let outcome = vm.openProject(at: url)
        if case .failed(let error) = outcome {
            #expect(error is SHProjectError)
        } else {
            Issue.record("Expected .failed outcome, got \(outcome)")
        }
        #expect(vm.recentProjectURLs.isEmpty)
    }

    /// `recheckServerNow` must short-circuit (no fetchModels call, no
    /// long status text) when there's no selected server. Tests the
    /// guard at the top of the method — the actual cancellation
    /// behavior on the in-flight task needs a mock client which the vm
    /// doesn't currently support, but this guard is the first line of
    /// defense against spurious pings from a half-configured vm.
    @MainActor
    @Test func recheckServerNowReturnsImmediatelyWithoutSelectedServer() async {
        let vm = SHDocumentViewModel(persistenceMode: .scratch)
        // Clear any seed servers loaded from the registry so
        // `selectedServer` returns nil.
        vm.servers = []
        vm.config.selectedServerID = nil

        await vm.recheckServerNow()
        #expect(vm.statusText == "Není vybraný server")
    }

    /// Cross-window sync: when one view-model posts the recents-changed
    /// notification, peer view-models must reload from UserDefaults so
    /// their `Otevřít nedávné…` menu reflects the latest list without
    /// an app restart.
    @MainActor
    @Test func recentProjectsObserverRefreshesPeerOnPost() async throws {
        let recentKey = "SHRecentProjects"
        let bookmarksKey = "SHProjectBookmarks"
        let priorPaths = UserDefaults.standard.object(forKey: recentKey)
        let priorBookmarks = UserDefaults.standard.object(forKey: bookmarksKey)
        defer {
            UserDefaults.standard.set(priorPaths, forKey: recentKey)
            UserDefaults.standard.set(priorBookmarks, forKey: bookmarksKey)
        }

        UserDefaults.standard.removeObject(forKey: recentKey)
        UserDefaults.standard.removeObject(forKey: bookmarksKey)

        let observer = SHDocumentViewModel(persistenceMode: .scratch)
        #expect(observer.recentProjectURLs.isEmpty)

        // Simulate the side effect of another vm's
        // `persistRecentProjectsAndBookmarks`: write to UserDefaults
        // then broadcast. Pass `object: nil` so the observer doesn't
        // treat the post as self-originated.
        let peerPath = "/tmp/sh-peer-\(UUID().uuidString).spiceharvester.json"
        UserDefaults.standard.set([peerPath], forKey: recentKey)
        NotificationCenter.default.post(
            name: SHDocumentViewModel.recentProjectsDidChange,
            object: nil
        )

        // NotificationCenter dispatches observer blocks onto
        // OperationQueue.main asynchronously. Poll up to ~500 ms so
        // the test isn't flaky on busy machines while staying fast on
        // the happy path (usually one iteration).
        for _ in 0..<50 {
            if !observer.recentProjectURLs.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(observer.recentProjectURLs.map(\.path) == [peerPath])
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "SpiceHarvesterTests" {
            let next = url.deletingLastPathComponent()
            if next == url { break }
            url = next
        }
        return url.deletingLastPathComponent()
    }
}

struct NoopOCRProvider: SHOCRProviding {
    func extractText(from fileURL: URL) async throws -> [String] {
        Issue.record("OCR should not be called for plain text documents: \(fileURL.lastPathComponent)")
        return []
    }
}
