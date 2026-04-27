import Foundation
import Testing
@testable import SpiceHarvester

struct SpiceHarvesterTests {
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
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = csv.split(separator: "\n")

        #expect(lines.count == 3) // header + 2 dokumenty
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
}
