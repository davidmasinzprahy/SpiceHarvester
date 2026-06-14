# CLI nástroje — Fáze 2 (csvkit / XLSX→CSV) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rozšířit konverzní vrstvu o převod tabulek XLSX/XLS na CSV pomocí csvkit (`in2csv`), aby je pipeline uměla vytěžit jako text — pod App Sandboxem, s graceful fallbackem na nativní cestu.

**Architecture:** Mechanika z Fáze 1 už existuje (`SHToolRuntime`, `SHToolRegistry`, `SHDocumentConverter`, pipeline integrace). Fáze 2 přidá nástroj `in2csv` jako další `SHTool`, novou routu `.csvkit` (přípony `xlsx`/`xls` se rozhodují čistě podle přípony — binární tabulky nemají nativní textovou cestu), exec `in2csv <soubor>` → CSV na stdout → `SHPDFParseResult`. `in2csv` je Python skript, takže packaging bundluje relokovatelný Python + csvkit + tenký wrapper do `Contents/Helpers/` (jako infra, s manuálním Xcode krokem stejně jako ve Fázi 1).

**Tech Stack:** Swift 5, Foundation `Process`, Swift Testing, csvkit `in2csv` 2.x (Python), python-build-standalone, Xcode 16.

---

## Referenční dokumenty

- Spec: `docs/superpowers/specs/2026-06-13-cli-nastroje-vytezovani-design.md` (sekce „Fáze 2 — tabulky")
- Fáze 1 plán (vzory): `docs/superpowers/plans/2026-06-13-cli-nastroje-faze1-pandoc-poppler.md`

## Konvence pro tento repozitář (DŮLEŽITÉ)

- **Commity bez jakékoli Claude atribuce.** Žádné `Co-Authored-By`, `Claude`, `noreply@anthropic.com` — `scripts/check_contributor_hygiene.py` skenuje celou historii a shodí CI. Autor/committer `davidmasinzprahy <david.masin@gmail.com>`.
- **Commituj přímo na `main`.**
- Po každém commitu spusť `python3 scripts/check_contributor_hygiene.py` — musí vypsat `OK`.
- **Xcode synchronizované složky** (`objectVersion = 77`): `.swift` soubory v `SpiceHarvester/` a `SpiceHarvesterTests/` jsou automaticky v targetu. NEEDITUJ `SpiceHarvester.xcodeproj/project.pbxproj`.

## Test/build příkazy

Unit testy:
```bash
xcodebuild test \
  -project SpiceHarvester.xcodeproj -scheme SpiceHarvester \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:SpiceHarvesterTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Konkrétní test (`<NÁZEV>`):
```bash
xcodebuild test -project SpiceHarvester.xcodeproj -scheme SpiceHarvester \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:SpiceHarvesterTests/SHToolingTests/<NÁZEV> \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Release build:
```bash
xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester \
  -configuration Release -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

## Současný stav (z Fáze 1, ověřeno)

- `SHTool` (`SpiceHarvester/Services/SHTool.swift`): enum `String, CaseIterable, Sendable`, cases `pandoc`, `pdftotext`, `pdfinfo`; `var executableName: String { rawValue }`; `var versionArguments: [String] { ["--version"] }`. Plus `SHToolResult`, `SHToolError`.
- `SHDocumentConverter` (`SpiceHarvester/Services/SHDocumentConverter.swift`): `enum Route: Sendable, Equatable { case native; case pandoc; case popplerText }`; `static let pandocExtensions: Set<String>`; `let runtime: SHToolRuntime`; `static func route(for fileURL: URL, popplerPDFTextEnabled: Bool) -> Route`; `func convert(fileURL:popplerPDFTextEnabled:) async -> SHPDFParseResult?` switching on route to private `runPandoc`/`runPdftotext`.
- `SHAppConfig` (`SpiceHarvester/Models/SHAppConfig.swift`): má `officeConversionEnabled: Bool = true`, `popplerPDFTextEnabled: Bool = false`, vlastní `CodingKeys` + `init(from:)` s `decodeIfPresent(...) ?? default`. Decoder container je `c`.
- `SHPreprocessingPipeline` (`SpiceHarvester/Pipeline/SHPreprocessingPipeline.swift`): init má `converter`, `officeConversionEnabled`, `popplerPDFTextEnabled` (před `ocrProvider`, s defaulty). `parseText(from:) async -> SHPDFParseResult` počítá `converterAllowed = (officeExtension && officeConversionEnabled) || (ext == "pdf" && popplerPDFTextEnabled)`.
- `SHFileScanService.supportedDocumentExtensions` už obsahuje `xlsx`, `xls`.
- `SHAppViewModel` (řádky ~2493): konstruuje pipeline, předává converter + flags z `config`, a do signatury přidává `await SHToolRegistry().signatureComponent(for: [.pandoc, .pdftotext])` jen když `config.officeConversionEnabled || config.popplerPDFTextEnabled`.
- `SettingsView` (`ocrTab`): sekce „Lokální nástroje" se dvěma toggly + stavem `pandoc`/`pdftotext`; helper `toolStatusLabel(_:)`; `.task` plní stav přes `SHToolRegistry`.
- Testy: `SpiceHarvesterTests/SHToolingTests.swift` (`@Suite struct SHToolingTests`); sdílený `struct NoopOCRProvider` (bez `private`) v `SpiceHarvesterTests/SpiceHarvesterTests.swift`.

## Mapa souborů

- Modify: `SpiceHarvester/Services/SHTool.swift` — přidat case `in2csv`
- Modify: `SpiceHarvester/Services/SHDocumentConverter.swift` — `Route.csvkit`, `csvkitExtensions`, route + `runIn2csv`
- Modify: `SpiceHarvester/Models/SHAppConfig.swift` — `spreadsheetConversionEnabled`
- Modify: `SpiceHarvester/Pipeline/SHPreprocessingPipeline.swift` — gate pro csvkit v `parseText`
- Modify: `SpiceHarvester/ViewModels/SHAppViewModel.swift` — předat flag, přidat `.in2csv` do tool signatury
- Modify: `SpiceHarvester/Views/SettingsView.swift` — toggle + stav pro `in2csv`
- Create: `scripts/bundle_python_tools.sh` — bundle relokovatelného Pythonu + csvkit + wrapper `in2csv`
- Modify: `SpiceHarvesterTests/SHToolingTests.swift` — testy
- Modify: `README.md`, `docs/KODOVA_DOKUMENTACE.md` — dokumentace

## Rozhodnutí (defaulty pro tuto fázi)

- **Toggle default:** `spreadsheetConversionEnabled = true` (konzistentní s office konverzí).
- **Více listů:** `in2csv` bere ve výchozím stavu první list. Pro Fázi 2 stačí první list; multi-sheet (`--use-sheet-names`/`--write-sheets`) je mimo rozsah.
- **Routing XLSX:** `route` vrací `.csvkit` pro `xlsx`/`xls` vždy (binární tabulky nemají smysluplnou nativní textovou cestu); o tom, zda se converter zavolá, rozhoduje až `spreadsheetConversionEnabled` v pipeline. Tím se NEMĚNÍ signatura `route(for:popplerPDFTextEnabled:)`.
- **Packaging:** relokovatelný Python (python-build-standalone) + `pip install csvkit`; spouštět přes tenký wrapper `Contents/Helpers/in2csv` (shebang nemůže ukazovat na `@executable_path`).

---

### Task 1: Přidat `SHTool.in2csv`

**Files:**
- Modify: `SpiceHarvester/Services/SHTool.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

- [ ] **Step 1: Napiš padající test.** Přidej do `SHToolingTests`:
```swift
    @Test func in2csvToolNameAndVersionArgs() {
        #expect(SHTool.in2csv.executableName == "in2csv")
        #expect(SHTool.in2csv.versionArguments == ["--version"])
        #expect(SHTool.allCases.contains(.in2csv))
    }
```

- [ ] **Step 2: Ověř selhání.** Run: `...SHToolingTests/in2csvToolNameAndVersionArgs`. Expected: FAIL — „type 'SHTool' has no member 'in2csv'".

- [ ] **Step 3: Přidej case.** V `SHTool.swift` do enumu `SHTool` přidej za `case pdfinfo`:
```swift
    case in2csv
```
(`executableName` a `versionArguments` jsou společné — `in2csv --version` vypisuje `in2csv 2.2.0`, takže fungují beze změny.)

- [ ] **Step 4: Ověř.** Run test. Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add SpiceHarvester/Services/SHTool.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "Tooling: přidej nástroj in2csv (csvkit)"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 2: Route `.csvkit` + konverze `runIn2csv`

**Files:**
- Modify: `SpiceHarvester/Services/SHDocumentConverter.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

> `in2csv <soubor.xlsx>` vypíše CSV na stdout (formát se detekuje podle přípony). Výsledek je jeden „page".

- [ ] **Step 1: Napiš padající testy.** Přidej do `SHToolingTests`:
```swift
    @Test func converterRoutesSpreadsheetsToCsvkit() {
        func route(_ name: String) -> SHDocumentConverter.Route {
            SHDocumentConverter.route(for: URL(fileURLWithPath: "/tmp/\(name)"), popplerPDFTextEnabled: false)
        }
        #expect(route("a.xlsx") == .csvkit)
        #expect(route("a.XLS") == .csvkit)
        #expect(route("a.csv") == .native)   // čisté CSV zůstává nativní
        #expect(route("a.docx") == .pandoc)  // beze změny
    }

    // Integrační test: vytvořit binární XLSX ze Swiftu je netriviální (není po ruce
    // XLSX writer), proto se test spustí jen když existuje fixture na disku a in2csv
    // je dostupný; jinak se přeskočí. CSV s in2csv NEtestujeme (čisté CSV jde nativně).
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
```

- [ ] **Step 2: Ověř selhání.** Run: `...SHToolingTests/converterRoutesSpreadsheetsToCsvkit`. Expected: FAIL — `.csvkit` neexistuje.

- [ ] **Step 3: Uprav `SHDocumentConverter.swift`.**

(a) Do `enum Route` přidej case:
```swift
        case csvkit       // tabulky (xlsx/xls) -> CSV přes in2csv
```

(b) Přidej statickou množinu vedle `pandocExtensions`:
```swift
    /// Tabulkové formáty řešené csvkit (in2csv).
    static let csvkitExtensions: Set<String> = ["xlsx", "xls"]
```

(c) V `route(for:popplerPDFTextEnabled:)` přidej PŘED `if ext == "pdf"` větev:
```swift
        if csvkitExtensions.contains(ext) { return .csvkit }
```

(d) V `convert(fileURL:popplerPDFTextEnabled:)` do `switch` přidej case:
```swift
        case .csvkit:
            return await runIn2csv(fileURL)
```

(e) Přidej privátní metodu (vedle `runPandoc`/`runPdftotext`):
```swift
    private func runIn2csv(_ fileURL: URL) async -> SHPDFParseResult? {
        guard runtime.resolve(.in2csv) != nil else { return nil }
        // in2csv detekuje formát podle přípony a píše CSV na stdout
        guard let result = try? await runtime.run(.in2csv, arguments: [fileURL.path], timeout: 120),
              result.exitCode == 0 else { return nil }
        let text = result.stdoutString
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHPDFParseResult(rawPages: [text], hasTextLayer: !trimmed.isEmpty, pageCount: 1)
    }
```

- [ ] **Step 4: Ověř.** Run testy. `converterRoutesSpreadsheetsToCsvkit` PASS; `converterConvertsXlsxWhenAvailable` PASS nebo přeskočen (chybí-li in2csv nebo fixture).

- [ ] **Step 5: Commit.**
```bash
git add SpiceHarvester/Services/SHDocumentConverter.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "Converter: route a konverze XLSX/XLS přes in2csv"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 3: Přepínač `spreadsheetConversionEnabled` v `SHAppConfig`

**Files:**
- Modify: `SpiceHarvester/Models/SHAppConfig.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

- [ ] **Step 1: Napiš padající test.** Přidej do `SHToolingTests`:
```swift
    @Test func appConfigSpreadsheetDefaultAndRoundtrip() throws {
        let config = SHAppConfig()
        #expect(config.spreadsheetConversionEnabled == true)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SHAppConfig.self, from: data)
        #expect(decoded.spreadsheetConversionEnabled == true)
    }
```

- [ ] **Step 2: Ověř selhání.** Run: `...SHToolingTests/appConfigSpreadsheetDefaultAndRoundtrip`. Expected: FAIL — „has no member 'spreadsheetConversionEnabled'".

- [ ] **Step 3: Přidej všechny TŘI části** do `SHAppConfig.swift`:

(a) Stored property (vedle `popplerPDFTextEnabled`):
```swift
    /// Konverze tabulek (XLSX/XLS) na CSV přes csvkit (in2csv). Default zapnuto.
    var spreadsheetConversionEnabled: Bool = true
```
(b) Do `enum CodingKeys`:
```swift
        case spreadsheetConversionEnabled
```
(c) Do `init(from decoder:)` (container `c`):
```swift
        spreadsheetConversionEnabled = try c.decodeIfPresent(Bool.self, forKey: .spreadsheetConversionEnabled) ?? true
```

- [ ] **Step 4: Ověř.** Run test. Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add SpiceHarvester/Models/SHAppConfig.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "Config: přepínač spreadsheetConversionEnabled"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 4: Zapojení csvkit do `SHPreprocessingPipeline`

**Files:**
- Modify: `SpiceHarvester/Pipeline/SHPreprocessingPipeline.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

> Pipeline dostane další flag `spreadsheetConversionEnabled` (init param s defaultem `false` pro zpětnou kompatibilitu) a v `parseText` rozšíří `converterAllowed`.

- [ ] **Step 1: Napiš padající test.** Přidej do `SHToolingTests`:
```swift
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
```

- [ ] **Step 2: Ověř selhání.** Run: `...SHToolingTests/pipelineAcceptsSpreadsheetFlagAndKeepsNativeForText`. Expected: FAIL — init nemá `spreadsheetConversionEnabled`.

- [ ] **Step 3: Uprav `SHPreprocessingPipeline.swift`.**

(a) Přidej stored property vedle ostatních:
```swift
    private let spreadsheetConversionEnabled: Bool
```
(b) Do init signatury přidej parametr za `popplerPDFTextEnabled` (s defaultem `false`) a přiřaď ho:
```swift
        popplerPDFTextEnabled: Bool = false,
        spreadsheetConversionEnabled: Bool = false,
        ocrProvider: SHOCRProviding,
```
a v těle:
```swift
        self.spreadsheetConversionEnabled = spreadsheetConversionEnabled
```
(c) V `parseText(from:)` rozšiř výpočet. Nahraď stávající blok:
```swift
        let ext = fileURL.pathExtension.lowercased()
        let officeExtension = SHDocumentConverter.pandocExtensions.contains(ext)

        // converter zkus jen když je relevantní a povolený
        let converterAllowed = (officeExtension && officeConversionEnabled)
            || (ext == "pdf" && popplerPDFTextEnabled)
```
za:
```swift
        let ext = fileURL.pathExtension.lowercased()
        let officeExtension = SHDocumentConverter.pandocExtensions.contains(ext)
        let spreadsheetExtension = SHDocumentConverter.csvkitExtensions.contains(ext)

        // converter zkus jen když je relevantní a povolený
        let converterAllowed = (officeExtension && officeConversionEnabled)
            || (ext == "pdf" && popplerPDFTextEnabled)
            || (spreadsheetExtension && spreadsheetConversionEnabled)
```
(Zbytek `parseText` — volání `converter.convert(...)` a nativní fallback — zůstává beze změny.)

- [ ] **Step 4: Ověř.** Run testy. Nový test PASS; stávající `pipelineUsesConverterThenFallsBackToNative` a `preprocessingPipelineReadsPlainTextDocumentsWithoutOCR` stále PASS.

- [ ] **Step 5: Commit.**
```bash
git add SpiceHarvester/Pipeline/SHPreprocessingPipeline.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "Pipeline: gate pro konverzi tabulek přes csvkit"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 5: Předání flagu + `in2csv` v cache signatuře (ViewModel)

**Files:**
- Modify: `SpiceHarvester/ViewModels/SHAppViewModel.swift`

> V místě konstrukce pipeline (řádky ~2493) předej nový flag a rozšiř tool signaturu o `.in2csv`, gate i na `spreadsheetConversionEnabled`.

- [ ] **Step 1: Najdi konstrukci.**
```bash
grep -n "SHPreprocessingPipeline(\|signatureComponent(for:\|officeConversionEnabled:" SpiceHarvester/ViewModels/SHAppViewModel.swift
```

- [ ] **Step 2: Uprav gate signatury.** Nahraď podmínku a volání signatury (z Fáze 1):
```swift
            if config.officeConversionEnabled || config.popplerPDFTextEnabled {
                let toolSignature = await SHToolRegistry().signatureComponent(for: [.pandoc, .pdftotext])
                preprocessSignature += "|tools:" + toolSignature
            }
```
za:
```swift
            if config.officeConversionEnabled || config.popplerPDFTextEnabled || config.spreadsheetConversionEnabled {
                let toolSignature = await SHToolRegistry().signatureComponent(for: [.pandoc, .pdftotext, .in2csv])
                preprocessSignature += "|tools:" + toolSignature
            }
```

- [ ] **Step 3: Předej flag do initu.** V `SHPreprocessingPipeline(...)` přidej za `popplerPDFTextEnabled: config.popplerPDFTextEnabled,`:
```swift
                spreadsheetConversionEnabled: config.spreadsheetConversionEnabled,
```

- [ ] **Step 4: Build + testy.**
```bash
xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Release -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
xcodebuild test -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Debug -destination 'platform=macOS' -only-testing:SpiceHarvesterTests CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```
Expected: build OK, testy PASS.

- [ ] **Step 5: Commit.**
```bash
git add SpiceHarvester/ViewModels/SHAppViewModel.swift
git commit -m "Pipeline: předej flag tabulek a in2csv do cache signatury"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 6: Settings — toggle a stav `in2csv`

**Files:**
- Modify: `SpiceHarvester/Views/SettingsView.swift`

> UI nemá unit testy; ověřuje se Release buildem. Drž styl sekce „Lokální nástroje" v `ocrTab` z Fáze 1.

- [ ] **Step 1: Přidej `@State`** vedle `pandocStatusText`/`pdftotextStatusText`:
```swift
    @State private var in2csvStatusText = "Zjišťuji…"
```

- [ ] **Step 2: Přidej toggle + status řádek** do sekce „Lokální nástroje" v `ocrTab` (za toggle `popplerPDFTextEnabled` a za jeho `LabeledContent`y):
```swift
                Toggle(isOn: $vm.config.spreadsheetConversionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Konverze tabulek (XLSX/XLS) přes csvkit")
                        Text("Tabulky se převedou na CSV přes in2csv.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("in2csv") {
                    Text(in2csvStatusText).foregroundStyle(.secondary)
                }
```

- [ ] **Step 3: Rozšiř `.onChange` a `.task`** v `ocrTab`. Přidej za stávající `.onChange(of: vm.config.popplerPDFTextEnabled)`:
```swift
        .onChange(of: vm.config.spreadsheetConversionEnabled) { _, _ in vm.persistAll() }
```
a do `.task` bloku přidej řádek:
```swift
            in2csvStatusText = Self.toolStatusLabel(await registry.status(for: .in2csv))
```

- [ ] **Step 4: Rozšiř keywords.** V `enum SettingsTab` u `case .ocr` přidej do `searchKeywords`: `"csvkit"`, `"in2csv"`, `"xlsx"`, `"tabulky"`, `"excel"`.

- [ ] **Step 5: Release build + test.**
```bash
xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Release -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
xcodebuild test -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Debug -destination 'platform=macOS' -only-testing:SpiceHarvesterTests CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`, testy PASS.

- [ ] **Step 6: Commit.**
```bash
git add SpiceHarvester/Views/SettingsView.swift
git commit -m "Settings: přepínač a stav konverze tabulek (in2csv)"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 7: Packaging — bundle Pythonu + csvkit

**Files:**
- Create: `scripts/bundle_python_tools.sh`

> `in2csv` je Python skript se shebangem na absolutní cestu, takže nestačí zkopírovat binárku — je třeba relokovatelný Python + csvkit + tenký wrapper. Skript nelze v tomto prostředí plně spustit (vyžaduje stažení python-build-standalone a `pip`); ověřuje se SYNTAX a graceful chování. Xcode Run Script fáze je manuální krok (pbxproj se needituje).

- [ ] **Step 1: Vytvoř `scripts/bundle_python_tools.sh`:**
```bash
#!/usr/bin/env bash
# Vloží relokovatelný Python + csvkit do <APP>/Contents/Helpers/python a vytvoří
# tenký wrapper Contents/Helpers/in2csv. Spouští se jako Xcode Run Script phase
# nebo ručně: ./scripts/bundle_python_tools.sh /cesta/SpiceHarvester.app "-"
#
# Vyžaduje proměnnou PBS_URL s odkazem na python-build-standalone tarball
# (https://github.com/astral-sh/python-build-standalone/releases) pro cílovou
# architekturu, např. cpython-3.12.*-aarch64-apple-darwin-install_only.tar.gz
set -euo pipefail

APP="${1:-${CODESIGNING_FOLDER_PATH:?chybí cesta k .app}}"
SIGN_ID="${2:-${EXPANDED_CODE_SIGN_IDENTITY:--}}"
PBS_URL="${PBS_URL:?nastav PBS_URL na python-build-standalone tarball}"
HELPERS="$APP/Contents/Helpers"
PYDIR="$HELPERS/python"
mkdir -p "$HELPERS"

# 1) Stáhni a rozbal relokovatelný Python (idempotentně)
if [ ! -x "$PYDIR/bin/python3" ]; then
  tmp="$(mktemp -d)"
  curl -fsSL "$PBS_URL" -o "$tmp/python.tar.gz"
  rm -rf "$PYDIR"
  mkdir -p "$PYDIR"
  # tarball má kořen "python/" -> rozbal o úroveň výš a přesuň
  tar -xzf "$tmp/python.tar.gz" -C "$tmp"
  mv "$tmp/python/"* "$PYDIR/"
  rm -rf "$tmp"
fi

# 2) Nainstaluj csvkit do bundlovaného Pythonu
"$PYDIR/bin/python3" -m pip install --upgrade --no-warn-script-location csvkit

# 3) Tenký wrapper: shebang nemůže být @executable_path, proto wrapper přes bash
cat > "$HELPERS/in2csv" <<'WRAP'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/python/bin/python3" -m csvkit.utilities.in2csv "$@"
WRAP
chmod +x "$HELPERS/in2csv"

# 4) Podepiš všechny Mach-O (python binárky, .so moduly) i wrapper
find "$PYDIR" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -exec \
  codesign --force --options runtime --timestamp=none -s "$SIGN_ID" {} \; 2>/dev/null || true
codesign --force --options runtime --timestamp=none -s "$SIGN_ID" "$HELPERS/in2csv"

echo "Hotovo: Python + csvkit v $PYDIR, wrapper $HELPERS/in2csv"
```

- [ ] **Step 2: Zpřístupni skript.**
```bash
chmod +x scripts/bundle_python_tools.sh
```

- [ ] **Step 3: Ověř syntax.**
```bash
bash -n scripts/bundle_python_tools.sh && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`.

- [ ] **Step 4: Ověř graceful chování bez PBS_URL.** Run (musí selhat s čitelnou hláškou na chybějící `PBS_URL`, exit != 0, bez stahování):
```bash
( unset PBS_URL; ./scripts/bundle_python_tools.sh /tmp/x-$RANDOM.app "-" ); echo "exit=$?"
```
Zaznamenej výstup a exit kód. Expected: hláška `nastav PBS_URL ...`, `exit=1`.

- [ ] **Step 5: Commit.**
```bash
git add scripts/bundle_python_tools.sh
git commit -m "Packaging: skript pro bundle Pythonu a csvkit (in2csv) do .app"
python3 scripts/check_contributor_hygiene.py
```

- [ ] **Step 6: Zdokumentuj manuální krok** (NEPROVÁDĚJ — nahlas v reportu): do existující Run Script fáze (z Fáze 1) přidat druhý řádek `"${SRCROOT}/scripts/bundle_python_tools.sh"` a nastavit env `PBS_URL` (build setting nebo v těle skriptu) na python-build-standalone tarball pro cílovou architekturu. Pozn.: výrazně zvětší `.app`.

---

### Task 8: Dokumentace + finální build/test

**Files:**
- Modify: `README.md`, `docs/KODOVA_DOKUMENTACE.md`

> `check_czech_quotes.py` lintuje jen `.swift` v `SpiceHarvester/`; README/docs neřeší. `check_contributor_hygiene.py` ale README skenuje — žádné zakázané řetězce.

- [ ] **Step 1: README — podporované vstupy.** V „## K čemu slouží" přidej bullet (additivně, neměň chráněné fráze `macOS 15.6+`, `Výchozí režim aplikace je **SEARCH**.`, `PDF soubory nebo jinými typy souborů`, `SPARK DGX`):
```
- konverze tabulek (XLSX, XLS) na CSV přes csvkit
```

- [ ] **Step 2: KODOVA_DOKUMENTACE.md.** Do sekce „Konverzní vrstva (lokální CLI nástroje)" přidej odstavec, že `SHDocumentConverter` routuje `xlsx`/`xls` přes `in2csv` (csvkit) na CSV, a že packaging bundluje relokovatelný Python + csvkit přes `scripts/bundle_python_tools.sh`.

- [ ] **Step 3: Linty.**
```bash
python3 scripts/check_czech_quotes.py
python3 scripts/check_contributor_hygiene.py
```
Expected: oba `OK`.

- [ ] **Step 4: Plný build + test.**
```bash
xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Release -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
xcodebuild test -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Debug -destination 'platform=macOS' -only-testing:SpiceHarvesterTests CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: `BUILD SUCCEEDED`; všechny testy PASS (vč. `readmeDoesNotRegressKnownDocumentationFacts`).

- [ ] **Step 5: Commit.**
```bash
git add README.md docs/KODOVA_DOKUMENTACE.md
git commit -m "Docs: zdokumentuj konverzi tabulek přes csvkit"
python3 scripts/check_contributor_hygiene.py
```

---

## Hotová Fáze 2 znamená

- Aplikace zpracuje XLSX/XLS (první list) přes `in2csv` → CSV → text.
- Chybějící `in2csv` nikdy neshodí pipeline (fallback na nativní cestu).
- Stav `in2csv` a přepínač jsou v Settings; verze `in2csv` vstupuje do cache signatury.
- Skript pro bundle Pythonu + csvkit existuje (Xcode wiring + `PBS_URL` jsou manuální krok).

## Navazující fáze (samostatný plán)

- **Fáze 3 — ocrmypdf + tesseract + ghostscript (OCR skenů):** nová OCR větev v converteru pro PDF bez textové vrstvy; bundlovat Python + ghostscript (AGPL — poznámka v licencích) + tesseract + `tessdata` (`ces, slk, deu, pol, eng`). Pozn.: před první notarizací přepnout `codesign --timestamp=none` na `--timestamp` (i v `bundle_tools.sh` / `bundle_python_tools.sh`).
