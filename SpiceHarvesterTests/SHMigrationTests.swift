import Testing
import Foundation
@testable import SpiceHarvester

struct SHMigrationTests {
    @Test func splitsLegacyConfigIntoContentAndPrefs() {
        var legacy = SHAppConfig()
        legacy.inputFolder = "/in"
        legacy.selectedInferenceModel = "qwen"
        legacy.extractionMode = .consolidate
        legacy.currentPrompt = "p"
        legacy.requestTimeoutSeconds = 300
        legacy.ocrLanguages = "deu+eng"
        legacy.maxConcurrentInference = 8

        let split = SHMigration.split(legacy)
        #expect(split.content.inputFolder == "/in")
        #expect(split.content.selectedInferenceModel == "qwen")
        #expect(split.content.extractionMode == .consolidate)
        #expect(split.content.currentPrompt == "p")
        #expect(split.prefs.requestTimeoutSeconds == 300)
        #expect(split.prefs.ocrLanguages == "deu+eng")
        #expect(split.prefs.maxConcurrentInference == 8)
    }

    @Test func preferencesStoreRoundtrips() {
        let defaults = UserDefaults(suiteName: "test-prefs-\(UUID().uuidString)")!
        let store = SHPreferencesStore(defaults: defaults)
        var p = SHAppPreferences()
        p.requestTimeoutSeconds = 123
        store.save(p)
        #expect(store.load().requestTimeoutSeconds == 123)
    }

    @Test func preferencesStoreReturnsDefaultsWhenEmpty() {
        let defaults = UserDefaults(suiteName: "test-prefs-\(UUID().uuidString)")!
        let store = SHPreferencesStore(defaults: defaults)
        #expect(store.load().requestTimeoutSeconds == 600)
    }
}
