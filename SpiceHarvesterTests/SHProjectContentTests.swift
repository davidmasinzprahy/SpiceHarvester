import Testing
import Foundation
@testable import SpiceHarvester

struct SHProjectContentTests {
    @Test func projectContentRoundtrips() throws {
        var c = SHProjectContent()
        c.inputFolder = "/in"; c.selectedInferenceModel = "qwen"; c.extractionMode = .fast
        c.currentPrompt = "extract"; c.promptHistory = ["a", "b"]
        let data = try JSONEncoder().encode(c)
        let d = try JSONDecoder().decode(SHProjectContent.self, from: data)
        #expect(d.inputFolder == "/in")
        #expect(d.selectedInferenceModel == "qwen")
        #expect(d.extractionMode == .fast)
        #expect(d.promptHistory == ["a", "b"])
    }

    @Test func projectContentToleratesMissingKeys() throws {
        let json = "{\"inputFolder\":\"/x\"}".data(using: .utf8)!
        let d = try JSONDecoder().decode(SHProjectContent.self, from: json)
        #expect(d.inputFolder == "/x")
        #expect(d.extractionMode == .search) // default
        #expect(d.promptHistory.isEmpty)
    }

    @Test func appPreferencesDefaultsAndRoundtrip() throws {
        let p = SHAppPreferences()
        #expect(p.requestTimeoutSeconds == 600)
        #expect(p.ocrBackend == .appleVision)
        #expect(p.ocrLanguages == "ces+slk+deu+pol+eng")
        let data = try JSONEncoder().encode(p)
        let d = try JSONDecoder().decode(SHAppPreferences.self, from: data)
        #expect(d.requestTimeoutSeconds == 600)
        #expect(d.spreadsheetConversionEnabled == true)
    }
}
