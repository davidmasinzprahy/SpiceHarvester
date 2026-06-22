# DocumentGroup Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Převést Spice Harvester na document-based aplikaci (`DocumentGroup`) s rozdělením `SHAppViewModel` na global state + per-document VM + `ReferenceFileDocument`.

**Architecture:** `SHGlobalState` (servery/recents/app-prefs/služby) injektovaný přes environment; `SHProjectDocument: ReferenceFileDocument` (obsah projektu, autosave/verze); `SHDocumentViewModel` (per-okno runtime + run logika) konstruovaný z dokumentu + global.

**Tech Stack:** SwiftUI `DocumentGroup` / `ReferenceFileDocument`, `@Observable`, UniformTypeIdentifiers, Swift Testing, xcodebuild.

**Spec:** `docs/superpowers/specs/2026-06-21-documentgroup-refactor-design.md`

## Stav (2026-06-21)

Hotové a zelené (commitnuté, CI green):
- ✅ **F1** — `SHProjectContent` + `SHAppPreferences` + `SHPreferencesStore` + `SHMigration.split` + testy.
- ✅ **F2** — `SHGlobalState` (server registr) + VM pass-through.
- ✅ **F3** — rename `SHAppViewModel` → `SHDocumentViewModel`.
- ✅ **F4a** — `SHProjectDocument` (ReferenceFileDocument) + `UTType.spiceHarvesterProject`.
- ✅ **F4b-i** — app prefs přesunuty do `SHGlobalState`; Settings binduje `$global.prefs`.
- ✅ **F4b-ii (část)** — VM document-bridge scaffolding (aditivní): `document` property,
  `convenience init(document:global:)`, `applyProjectContent`/`currentProjectContent`,
  `persistAll` write-back do dokumentu. Zatím **nezapojeno** do scény.

Zbývá (vyžaduje samostatnou fokusovanou session — je to nedělitelný „big-bang"):
- 📋 **F4b-ii (zbytek)** — přepnout scénu `WindowGroup`→`DocumentGroup`, `ContentView(document:global:)`
  konstruuje VM, odstranit scratch `WindowGroup` + custom file/recents commands.
- 📋 **F5** — Settings plně odpojit od `vm` (per-dokumentové akce ven); AppIntents headless přes Default Project.
- 📋 **F6** — migrace při startu (legacy → Default Project) + úklid interimu + docs.

**Zjištěná kaskáda (proč je zbytek big-bang):** app-level Settings dnes hostuje
**per-dokumentové** akce — `Vyčistit cache` (`vm.clearCache()` nad cache složkou
projektu) a `setOCRBackend` (vedlejší efekty na VM). Ty se musí přesunout do hlavního
okna (ContentView), jinak Settings nejde odpojit od document-VM. Plus scéna nejde
půlit (build je rozbitý, dokud není celý přechod hotový). Proto se F4b-ii(zbytek)+F5+F6
musí udělat společně v jednom kuse.

**Postup:** Fázovaně se zeleným buildem po každé fázi. Fáze 1 je plně konkrétní a aditivní (nemění chování). Fáze 2–6 mají přesné deliverables + acceptance gate; jejich řádkové kroky se rozpracují při exekuci proti aktuálnímu kódu (refactor velkého VM nelze přesně předepsat dopředu, aniž by to byly skryté placeholdery).

---

## Fáze 1 — Datové modely + stores + migrace (aditivní, app beze změny)

Cíl: zavést `SHProjectContent`, `SHAppPreferences`, `SHPreferencesStore`, `SHMigration` jako nové typy s testy. Stávající `SHAppConfig` i VM zůstávají; nové typy se zatím nikde nepoužívají → app je celou fázi zelená.

### Task 1.1: `SHProjectContent` + `SHAppPreferences`

**Files:**
- Create: `SpiceHarvester/Models/SHProjectContent.swift`
- Test: `SpiceHarvesterTests/SHProjectContentTests.swift`

- [ ] **Step 1: Napiš failing testy**

```swift
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
```

- [ ] **Step 2: Spusť — fail** (`SHProjectContent` neexistuje)

Run: `xcodebuild test -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO -only-testing:SpiceHarvesterTests/SHProjectContentTests 2>&1 | tail -5`
Expected: build/test FAIL (unresolved `SHProjectContent`).

- [ ] **Step 3: Implementuj typy**

```swift
import Foundation

/// Obsah jednoho projektu = to, co se serializuje do `.spiceharvester.json`
/// dokumentu (DocumentGroup). Per-document; runtime stav sem nepatří.
struct SHProjectContent: Codable, Sendable {
    var inputFolder: String = ""
    var outputFolder: String = ""
    var cacheFolder: String = ""
    var promptFolder: String = ""
    /// Security-scoped bookmarky pro cesty projektu (přežijí restart v sandboxu).
    var folderBookmarks: [String: Data] = [:]
    var selectedServerID: UUID?
    var selectedInferenceModel: String = ""
    var selectedEmbeddingModel: String = ""
    var selectedRerankerModel: String = ""
    var selectedOCRModel: String = ""
    var extractionMode: SHExtractionMode = .search
    var currentPrompt: String = ""
    var lastLoadedPromptName: String = ""
    var promptHistory: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case inputFolder, outputFolder, cacheFolder, promptFolder, folderBookmarks
        case selectedServerID, selectedInferenceModel, selectedEmbeddingModel
        case selectedRerankerModel, selectedOCRModel, extractionMode
        case currentPrompt, lastLoadedPromptName, promptHistory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputFolder = try c.decodeIfPresent(String.self, forKey: .inputFolder) ?? ""
        outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder) ?? ""
        cacheFolder = try c.decodeIfPresent(String.self, forKey: .cacheFolder) ?? ""
        promptFolder = try c.decodeIfPresent(String.self, forKey: .promptFolder) ?? ""
        folderBookmarks = try c.decodeIfPresent([String: Data].self, forKey: .folderBookmarks) ?? [:]
        selectedServerID = try c.decodeIfPresent(UUID.self, forKey: .selectedServerID)
        selectedInferenceModel = try c.decodeIfPresent(String.self, forKey: .selectedInferenceModel) ?? ""
        selectedEmbeddingModel = try c.decodeIfPresent(String.self, forKey: .selectedEmbeddingModel) ?? ""
        selectedRerankerModel = try c.decodeIfPresent(String.self, forKey: .selectedRerankerModel) ?? ""
        selectedOCRModel = try c.decodeIfPresent(String.self, forKey: .selectedOCRModel) ?? ""
        extractionMode = try c.decodeIfPresent(SHExtractionMode.self, forKey: .extractionMode) ?? .search
        currentPrompt = try c.decodeIfPresent(String.self, forKey: .currentPrompt) ?? ""
        lastLoadedPromptName = try c.decodeIfPresent(String.self, forKey: .lastLoadedPromptName) ?? ""
        promptHistory = try c.decodeIfPresent([String].self, forKey: .promptHistory) ?? []
    }
}

/// App-level předvolby (Settings, Cmd+,) — sdílené přes všechny projekty.
/// Přesun z `SHAppConfig` (rozhodnutí A).
struct SHAppPreferences: Codable, Sendable {
    var maxConcurrentInference: Int = 4
    var maxConcurrentPDFWorkers: Int = max(2, ProcessInfo.processInfo.processorCount / 2)
    var throttleDelayMs: Int = 50
    var modelContextTokens: Int = 32_768
    var requestTimeoutSeconds: Int = 600
    var bypassInferenceCache: Bool = false
    var ocrBackend: SHOCRBackend = .appleVision
    var ocrLanguages: String = "ces+slk+deu+pol+eng"
    var ocrTimeoutSeconds: Int = 600
    var officeConversionEnabled: Bool = true
    var popplerPDFTextEnabled: Bool = false
    var spreadsheetConversionEnabled: Bool = true
    var lastRunAvgDocumentMs: Double = 0
    var lastRunAvgPageMs: Double = 0

    init() {}

    enum CodingKeys: String, CodingKey {
        case maxConcurrentInference, maxConcurrentPDFWorkers, throttleDelayMs
        case modelContextTokens, requestTimeoutSeconds, bypassInferenceCache
        case ocrBackend, ocrLanguages, ocrTimeoutSeconds
        case officeConversionEnabled, popplerPDFTextEnabled, spreadsheetConversionEnabled
        case lastRunAvgDocumentMs, lastRunAvgPageMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxConcurrentInference = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentInference) ?? 4
        maxConcurrentPDFWorkers = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentPDFWorkers)
            ?? max(2, ProcessInfo.processInfo.processorCount / 2)
        throttleDelayMs = try c.decodeIfPresent(Int.self, forKey: .throttleDelayMs) ?? 50
        modelContextTokens = try c.decodeIfPresent(Int.self, forKey: .modelContextTokens) ?? 32_768
        requestTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? 600
        bypassInferenceCache = try c.decodeIfPresent(Bool.self, forKey: .bypassInferenceCache) ?? false
        ocrBackend = try c.decodeIfPresent(SHOCRBackend.self, forKey: .ocrBackend) ?? .appleVision
        ocrLanguages = try c.decodeIfPresent(String.self, forKey: .ocrLanguages) ?? "ces+slk+deu+pol+eng"
        ocrTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .ocrTimeoutSeconds) ?? 600
        officeConversionEnabled = try c.decodeIfPresent(Bool.self, forKey: .officeConversionEnabled) ?? true
        popplerPDFTextEnabled = try c.decodeIfPresent(Bool.self, forKey: .popplerPDFTextEnabled) ?? false
        spreadsheetConversionEnabled = try c.decodeIfPresent(Bool.self, forKey: .spreadsheetConversionEnabled) ?? true
        lastRunAvgDocumentMs = try c.decodeIfPresent(Double.self, forKey: .lastRunAvgDocumentMs) ?? 0
        lastRunAvgPageMs = try c.decodeIfPresent(Double.self, forKey: .lastRunAvgPageMs) ?? 0
    }
}
```

- [ ] **Step 4: Spusť — pass**

Run: `xcodebuild test ... -only-testing:SpiceHarvesterTests/SHProjectContentTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add SpiceHarvester/Models/SHProjectContent.swift SpiceHarvesterTests/SHProjectContentTests.swift
git commit -m "DocumentGroup F1: SHProjectContent + SHAppPreferences modely + testy"
```

### Task 1.2: `SHPreferencesStore` + `SHMigration`

**Files:**
- Create: `SpiceHarvester/Services/SHPreferencesStore.swift`
- Create: `SpiceHarvester/Services/SHMigration.swift`
- Test: `SpiceHarvesterTests/SHMigrationTests.swift`

- [ ] **Step 1: Napiš failing testy**

```swift
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
        // content
        #expect(split.content.inputFolder == "/in")
        #expect(split.content.selectedInferenceModel == "qwen")
        #expect(split.content.extractionMode == .consolidate)
        #expect(split.content.currentPrompt == "p")
        // prefs
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
```

- [ ] **Step 2: Spusť — fail**

Run: `xcodebuild test ... -only-testing:SpiceHarvesterTests/SHMigrationTests 2>&1 | tail -5`
Expected: FAIL (unresolved `SHMigration` / `SHPreferencesStore`).

- [ ] **Step 3: Implementuj `SHPreferencesStore`**

```swift
import Foundation
import os

final class SHPreferencesStore {
    private enum Keys { static let prefs = "sh.appPreferences" }
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.spiceharvester", category: "Preferences")

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> SHAppPreferences {
        guard let data = defaults.data(forKey: Keys.prefs) else { return SHAppPreferences() }
        do { return try SHJSON.decoder().decode(SHAppPreferences.self, from: data) }
        catch {
            log.error("Failed to decode preferences, using defaults: \(error.localizedDescription, privacy: .public)")
            return SHAppPreferences()
        }
    }

    func save(_ prefs: SHAppPreferences) {
        do { defaults.set(try SHJSON.encoder(prettyPrinted: false).encode(prefs), forKey: Keys.prefs) }
        catch { log.error("Failed to encode preferences: \(error.localizedDescription, privacy: .public)") }
    }
}
```

- [ ] **Step 4: Implementuj `SHMigration`**

```swift
import Foundation

/// Rozdělení legacy `SHAppConfig` na obsah dokumentu + app prefs (rozhodnutí A).
/// Čistá funkce — testovatelná bez IO.
enum SHMigration {
    struct Split { let content: SHProjectContent; let prefs: SHAppPreferences }

    static func split(_ c: SHAppConfig) -> Split {
        var content = SHProjectContent()
        content.inputFolder = c.inputFolder
        content.outputFolder = c.outputFolder
        content.cacheFolder = c.cacheFolder
        content.promptFolder = c.promptFolder
        content.folderBookmarks = c.folderBookmarks
        content.selectedServerID = c.selectedServerID
        content.selectedInferenceModel = c.selectedInferenceModel
        content.selectedEmbeddingModel = c.selectedEmbeddingModel
        content.selectedRerankerModel = c.selectedRerankerModel
        content.selectedOCRModel = c.selectedOCRModel
        content.extractionMode = c.extractionMode
        content.currentPrompt = c.currentPrompt
        content.lastLoadedPromptName = c.lastLoadedPromptName

        var prefs = SHAppPreferences()
        prefs.maxConcurrentInference = c.maxConcurrentInference
        prefs.maxConcurrentPDFWorkers = c.maxConcurrentPDFWorkers
        prefs.throttleDelayMs = c.throttleDelayMs
        prefs.modelContextTokens = c.modelContextTokens
        prefs.requestTimeoutSeconds = c.requestTimeoutSeconds
        prefs.bypassInferenceCache = c.bypassInferenceCache
        prefs.ocrBackend = c.ocrBackend
        prefs.ocrLanguages = c.ocrLanguages
        prefs.ocrTimeoutSeconds = c.ocrTimeoutSeconds
        prefs.officeConversionEnabled = c.officeConversionEnabled
        prefs.popplerPDFTextEnabled = c.popplerPDFTextEnabled
        prefs.spreadsheetConversionEnabled = c.spreadsheetConversionEnabled
        prefs.lastRunAvgDocumentMs = c.lastRunAvgDocumentMs
        prefs.lastRunAvgPageMs = c.lastRunAvgPageMs
        return Split(content: content, prefs: prefs)
    }
}
```

> Pozn.: `promptHistory` je dnes mimo `SHAppConfig` (samostatná property VM); jeho
> migrace do `content.promptHistory` se zapojí ve Fázi 6, kde se napojuje migrace
> při startu a je k dispozici živá hodnota z VM.

- [ ] **Step 5: Spusť — pass**

Run: `xcodebuild test ... -only-testing:SpiceHarvesterTests/SHMigrationTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add SpiceHarvester/Services/SHPreferencesStore.swift SpiceHarvester/Services/SHMigration.swift SpiceHarvesterTests/SHMigrationTests.swift
git commit -m "DocumentGroup F1: SHPreferencesStore + SHMigration.split + testy"
```

---

## Fáze 2 — `SHGlobalState` (vyčlenit global z VM)

**Deliverable:** Nový `SpiceHarvester/State/SHGlobalState.swift` (`@MainActor @Observable`) vlastnící servery + serverStore + health + recents (+ stores) + app prefs (`SHAppPreferences` + `SHPreferencesStore`) + sdílené služby. `SHAppViewModel` tyto členy přestane vlastnit a začne je číst z injektované `SHGlobalState` reference (init parametr `global:`). Prefs, které dnes čte z `config` (timeout/concurrency/OCR/cache), se přesměrují na `global.prefs`. `SHAppConfig` ztratí prefs pole (zůstanou jen content pole) — nebo zůstanou a jen se nepoužívají; rozhodne se při exekuci dle nejmenšího rizika.

**Acceptance gate:**
- `xcodebuild build` zelený; existující testy (tooling/OCR/registry/config) zelené.
- Chování beze změny (app pořád single-window, jen interně rozdělená).
- Commit `DocumentGroup F2: SHGlobalState split`.

## Fáze 3 — `SHDocumentViewModel`

**Deliverable:** Přejmenovat `SHAppViewModel` → `SHDocumentViewModel`; `config` se zúží na referenci obsahu (zatím držený interně, dokument přijde ve F4). Runtime stav + run logika beze změny. Aktualizovat všechny referenční typy v testech (`SHAppViewModel` → `SHDocumentViewModel`).

**Acceptance gate:** build + testy zelené; commit `DocumentGroup F3: rename to SHDocumentViewModel`.

## Fáze 4 — `SHProjectDocument` + `DocumentGroup` scéna

**Deliverable:**
- `SpiceHarvester/Documents/SHProjectDocument.swift` (`ReferenceFileDocument`, snapshot `SHProjectContent`, fileWrapper JSON, UTType `.spiceHarvesterProject` z existující UTI).
- `SpiceHarvesterApp`: `WindowGroup`+scratch → `DocumentGroup(newDocument:)`; `ContentView(document:global:)` konstruuje `SHDocumentViewModel`; focused-VM routing menu commands; Help okno ponecháno.
- ContentView: všechny `vm.config.*` přístupy směrovat na document content (folders/modely/prompt/mode) resp. `global.prefs`.

**Acceptance gate:** build zelený; app se spustí, otevře/uloží/vytvoří `.spiceharvester.json`, native Open Recent funguje; manuální smoke test. Commit `DocumentGroup F4: DocumentGroup scéna + SHProjectDocument`.

## Fáze 5 — Settings + AppIntents

**Deliverable:**
- `SettingsView` bind na `globalState.prefs` (+ příslušné persistence přes `SHPreferencesStore`) místo `vm.config`.
- `RunSpiceHarvesterIntent` headless přes Default Project (rozhodnutí B): zkonstruovat `SHDocumentViewModel` proti sdílenému `SHGlobalState` + Default Project content, zachovat parametry (`mode`, `promptName`, `targetFolder`, wait, `ReturnsValue<String>`).

**Acceptance gate:** build + testy zelené; Settings mění app prefs; intent metadata se extrahují (`appintentsmetadataprocessor` bez chyby). Commit `DocumentGroup F5: Settings + AppIntents na global/Default Project`.

## Fáze 6 — Migrace při startu + úklid interimu

**Deliverable:**
- Zapojit `SHMigration` při startu (idempotentní flag v UserDefaults): legacy `SHConfigStore` config + živá `promptHistory` → `SHAppPreferences` (uložit) + `Default Project.spiceharvester.json`.
- Smazat interim: custom Save/Load Project commands, scratch `WindowGroup`, custom `recentProjectURLs` menu (nahrazeno nativním DocumentGroup Open Recent), související kód ve VM/App/AppDelegate.
- `application(_:open:)`: ponechat jen `.spice-result.json` větev (projekty řeší DocumentGroup).
- Dokumentace: README, KODOVA_DOKUMENTACE, NAPOVEDA, P2 backlog #2 → hotovo (plná varianta).

**Acceptance gate:** build + testy zelené; čistá migrace ze staré instalace (manuální ověření); CI green. Commit `DocumentGroup F6: migrace + úklid interimu + docs`.

---

## Self-Review

- **Spec coverage:** SHGlobalState (F2), SHProjectDocument (F4), SHDocumentViewModel (F3), SHAppConfig split (F1), scéna (F4), Settings global (F5), AppIntents B (F5), migrace (F1 split + F6 zapojení), úklid interimu (F6), testy (F1). Vše pokryto.
- **Placeholders:** Fáze 1 má kompletní kód + příkazy. Fáze 2–6 jsou deklarované jako deliverable+gate (ne vágní TODO) — řádkové kroky se rozpracují při exekuci proti aktuálnímu kódu, protože refactor 3108řádkového VM nelze přesně předepsat dopředu.
- **Type consistency:** `SHProjectContent` / `SHAppPreferences` / `SHMigration.split → Split{content,prefs}` / `SHPreferencesStore.load()/save()` konzistentní napříč F1 a referencemi ve F2–F6.
