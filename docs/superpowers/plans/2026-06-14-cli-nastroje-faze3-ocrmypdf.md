# CLI nástroje — Fáze 3 (ocrmypdf / OCR skenů) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Přidat lokální OCR skenovaných PDF přes ocrmypdf + tesseract jako nový OCR backend, s jazyky `ces+slk+deu+pol+eng`, pod App Sandboxem a s fallbackem na Apple Vision když nástroj chybí.

**Architecture:** OCR je v aplikaci abstrahované protokolem `SHOCRProviding` + enumem `SHOCRBackend` + řetězcem `SHFallbackOCRProvider`, vybírané v `makeOCRProvider()`. Fáze 3 přidá `SHOcrmypdfProvider: SHOCRProviding` (spustí `ocrmypdf --sidecar`, text rozdělí na stránky podle form-feed), nový case `SHOCRBackend.ocrmypdf` a zapojí ho jako primární s fallbackem na Vision. To realizuje „OCR větev" ze specu idiomaticky přes existující OCR abstrakci (čistší než konverzní vrstva — ta řeší extrakci textové vrstvy, ne rasterizovaný OCR). Packaging bundluje ocrmypdf (Python) + ghostscript (AGPL) + tesseract + `tessdata` do `Contents/Helpers/` (infra + manuální Xcode krok jako u Fáze 1/2).

**Tech Stack:** Swift 5, Foundation `Process`, Swift Testing, ocrmypdf (Python), tesseract 5.x, ghostscript, Xcode 16.

---

## Referenční dokumenty

- Spec: `docs/superpowers/specs/2026-06-13-cli-nastroje-vytezovani-design.md` (sekce „Fáze 3")
- Fáze 1/2 plány (vzory): `docs/superpowers/plans/2026-06-13-cli-nastroje-faze1-pandoc-poppler.md`, `docs/superpowers/plans/2026-06-14-cli-nastroje-faze2-csvkit.md`

## Konvence pro tento repozitář (DŮLEŽITÉ)

- **Commity bez jakékoli Claude atribuce** (`Co-Authored-By`, `Claude`, `noreply@anthropic.com`) — `scripts/check_contributor_hygiene.py` skenuje celou historii a shodí CI. Autor `davidmasinzprahy <david.masin@gmail.com>`.
- **Commituj přímo na `main`.** Po každém commitu `python3 scripts/check_contributor_hygiene.py` → musí být `OK`.
- **Xcode synchronizované složky** (`objectVersion = 77`): `.swift` v `SpiceHarvester/` a `SpiceHarvesterTests/` jsou automaticky v targetu. NEEDITUJ `project.pbxproj`.

## Test/build příkazy

Unit testy:
```bash
xcodebuild test -project SpiceHarvester.xcodeproj -scheme SpiceHarvester \
  -configuration Debug -destination 'platform=macOS' -only-testing:SpiceHarvesterTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Konkrétní test (`<NÁZEV>`): nahraď `-only-testing:SpiceHarvesterTests/SHToolingTests/<NÁZEV>`.

Release build:
```bash
xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester \
  -configuration Release -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

## Současný stav (ověřeno)

- `SHTool` (`SpiceHarvester/Services/SHTool.swift`): enum `String, CaseIterable, Sendable`, cases `pandoc, pdftotext, pdfinfo, in2csv`; `executableName == rawValue`; `versionArguments == ["--version"]`. Plus `SHToolResult`, `SHToolError`.
- `SHToolRuntime`: `resolve(_:) -> URL?` (helpers → PATH), `run(_:arguments:stdin:timeout:) async throws -> SHToolResult`. Init `SHToolRuntime(helpersDirectory:pathDirectories:)` — pro test lze `SHToolRuntime(helpersDirectory: nil, pathDirectories: [])` (resolve vrátí nil).
- `SHToolRegistry` actor: `signatureComponent(for: [SHTool]) async -> String`, `status(for:) async -> Status` (`.available(version:)` / `.missing`).
- OCR (`SpiceHarvester/Services/SHOCRProvider.swift`): `protocol SHOCRProviding: Sendable { func extractText(from fileURL: URL) async throws -> [String] }`. Implementace `SHVisionOCRProvider`, `SHOpenAIVisionOCRProvider`, `SHFallbackOCRProvider(primary:fallback:minimumUsableCharacters:)`.
- `SHOCRBackend` (v `SpiceHarvester/Models/SHAppConfig.swift`): enum `String, Codable, CaseIterable, Identifiable, Sendable`, cases `appleVision, openAIVision, appleVisionThenOpenAI`; `var title: String`.
- `makeOCRProvider() throws -> SHOCRProviding` (`SHAppViewModel.swift` ~2732) switch nad `config.ocrBackend`. `preprocessingSignature() -> String` (~2758) vrací `"ocr=appleVision"` apod.
- ViewModel konstrukce pipeline (~2493) skládá tool signaturu: `if config.officeConversionEnabled || config.popplerPDFTextEnabled || config.spreadsheetConversionEnabled { ... signatureComponent(for: [.pandoc, .pdftotext, .in2csv]) ... }`.
- Settings (`SpiceHarvester/Views/SettingsView.swift`): `ocrTab` má Picker přes `SHOCRBackend.allCases` (nový case se zobrazí sám) a sekci „Lokální nástroje" se stavem `pandoc`/`pdftotext`/`in2csv` (`@State` `*StatusText`, helper `toolStatusLabel(_:)`, `.task` přes `SHToolRegistry`).
- Testy: `SpiceHarvesterTests/SHToolingTests.swift` (`@Suite struct SHToolingTests`).

## Rozhodnutí (defaulty pro tuto fázi)

- **Integrace:** ocrmypdf jako `SHOCRProviding` + nový `SHOCRBackend.ocrmypdf`, NE jako converter routa. Default backend zůstává `appleVision` (žádná změna chování).
- **Fallback:** `SHOCRBackend.ocrmypdf` se v `makeOCRProvider()` zabalí jako `SHFallbackOCRProvider(primary: SHOcrmypdfProvider(), fallback: SHVisionOCRProvider())` — chybí-li ocrmypdf, OCR udělá Vision.
- **Jazyky:** napevno `ces+slk+deu+pol+eng` (odpovídá bundlovanému `tessdata`).
- **Volání:** `ocrmypdf -l <jazyky> --force-ocr --sidecar <sidecar.txt> <vstup.pdf> <výstup.pdf>` do dočasné složky; čte se jen sidecar text, stránky se dělí na form-feed `\u{0C}`. Chybějící nástroj / nenulový exit → vrátí `[]` (fallback řetězec to ošetří).
- **Packaging:** rozšíření Python bundle o ocrmypdf + bundle ghostscript (`gs`) + tesseract + `tessdata` (jen 5 jazyků). AGPL ghostscript → poznámka.

## Mapa souborů

- Modify: `SpiceHarvester/Services/SHTool.swift` — cases `ocrmypdf`, `tesseract`
- Create: `SpiceHarvester/Services/SHOcrmypdfProvider.swift` — OCR provider
- Modify: `SpiceHarvester/Models/SHAppConfig.swift` — `SHOCRBackend.ocrmypdf` + title
- Modify: `SpiceHarvester/ViewModels/SHAppViewModel.swift` — `makeOCRProvider`, `preprocessingSignature`, tool signatura
- Modify: `SpiceHarvester/Views/SettingsView.swift` — stav ocrmypdf/tesseract, footer pickeru
- Create: `scripts/bundle_ocr_tools.sh` — bundle ocrmypdf + ghostscript + tesseract + tessdata
- Modify: `SpiceHarvesterTests/SHToolingTests.swift` — testy
- Modify: `README.md`, `docs/KODOVA_DOKUMENTACE.md` — dokumentace

---

### Task 1: Nástroje `ocrmypdf` a `tesseract` v `SHTool`

**Files:** Modify `SpiceHarvester/Services/SHTool.swift`; Test `SpiceHarvesterTests/SHToolingTests.swift`

- [ ] **Step 1: Padající test.** Přidej do `SHToolingTests`:
```swift
    @Test func ocrToolNamesAndVersionArgs() {
        #expect(SHTool.ocrmypdf.executableName == "ocrmypdf")
        #expect(SHTool.tesseract.executableName == "tesseract")
        #expect(SHTool.ocrmypdf.versionArguments == ["--version"])
        #expect(SHTool.allCases.contains(.tesseract))
    }
```

- [ ] **Step 2: Ověř selhání.** Run `...SHToolingTests/ocrToolNamesAndVersionArgs`. Expected: FAIL — „has no member 'ocrmypdf'".

- [ ] **Step 3: Přidej cases.** V `enum SHTool` za `case in2csv`:
```swift
    case ocrmypdf
    case tesseract
```

- [ ] **Step 4: Ověř.** Run test. Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add SpiceHarvester/Services/SHTool.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "Tooling: přidej nástroje ocrmypdf a tesseract"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 2: `SHOcrmypdfProvider`

**Files:** Create `SpiceHarvester/Services/SHOcrmypdfProvider.swift`; Test `SpiceHarvesterTests/SHToolingTests.swift`

> Pure `parseSidecarPages` se testuje jednotkově; exec je gated integrační test. Chybějící nástroj → `[]` (fallback řetězec OCR to ošetří).

- [ ] **Step 1: Padající testy.** Přidej do `SHToolingTests`:
```swift
    @Test func ocrmypdfParsesSidecarPagesOnFormFeed() {
        let text = "Strana 1\u{0C}Strana 2\u{0C}Strana 3"
        let pages = SHOcrmypdfProvider.parseSidecarPages(text)
        #expect(pages.count == 3)
        #expect(pages[1] == "Strana 2")
    }

    @Test func ocrmypdfProviderReturnsEmptyWhenToolMissing() async throws {
        // runtime bez helpers i PATH -> resolve(.ocrmypdf) == nil
        let runtime = SHToolRuntime(helpersDirectory: nil, pathDirectories: [])
        let provider = SHOcrmypdfProvider(runtime: runtime)
        let pages = try await provider.extractText(from: URL(fileURLWithPath: "/tmp/none-\(UUID().uuidString).pdf"))
        #expect(pages.isEmpty)
    }
```

- [ ] **Step 2: Ověř selhání.** Run `...SHToolingTests/ocrmypdfParsesSidecarPagesOnFormFeed`. Expected: FAIL — „cannot find 'SHOcrmypdfProvider'".

- [ ] **Step 3: Vytvoř `SHOcrmypdfProvider.swift`:**
```swift
import Foundation

/// OCR skenovaných PDF přes lokální ocrmypdf (tesseract + ghostscript).
/// Spouští `ocrmypdf --sidecar`, vrací text po stránkách. Chybějící nástroj
/// nebo chyba => prázdné pole (řetězec SHFallbackOCRProvider sáhne po Vision).
final class SHOcrmypdfProvider: SHOCRProviding, Sendable {
    private let runtime: SHToolRuntime
    private let languages: String

    init(runtime: SHToolRuntime = SHToolRuntime(), languages: String = "ces+slk+deu+pol+eng") {
        self.runtime = runtime
        self.languages = languages
    }

    func extractText(from fileURL: URL) async throws -> [String] {
        guard runtime.resolve(.ocrmypdf) != nil else { return [] }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("ocrmypdf-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let outputPDF = workDir.appendingPathComponent("out.pdf")
        let sidecar = workDir.appendingPathComponent("sidecar.txt")

        // --force-ocr: skeny rasterizuj a vždy OCRuj (vstup nemá použitelnou textovou vrstvu).
        let args = ["-l", languages, "--force-ocr", "--sidecar", sidecar.path, fileURL.path, outputPDF.path]
        guard let result = try? await runtime.run(.ocrmypdf, arguments: args, timeout: 600),
              result.exitCode == 0,
              let text = try? String(contentsOf: sidecar, encoding: .utf8) else {
            return []
        }
        return Self.parseSidecarPages(text)
    }

    /// Čistá funkce: sidecar text dělí na stránky podle form-feed `\u{0C}`.
    static func parseSidecarPages(_ text: String) -> [String] {
        text.components(separatedBy: "\u{0C}")
    }
}
```

- [ ] **Step 4: Ověř.** Run testy. Oba PASS (`ocrmypdfProviderReturnsEmptyWhenToolMissing` nespouští exec — resolve vrátí nil).

- [ ] **Step 5: Commit.**
```bash
git add SpiceHarvester/Services/SHOcrmypdfProvider.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "OCR: SHOcrmypdfProvider (lokální OCR přes ocrmypdf)"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 3: `SHOCRBackend.ocrmypdf`

**Files:** Modify `SpiceHarvester/Models/SHAppConfig.swift`; Test `SpiceHarvesterTests/SHToolingTests.swift`

- [ ] **Step 1: Padající test.** Přidej do `SHToolingTests`:
```swift
    @Test func ocrBackendOcrmypdfExposesTitleAndIsCodable() throws {
        #expect(SHOCRBackend.ocrmypdf.title == "ocrmypdf")
        #expect(SHOCRBackend.allCases.contains(.ocrmypdf))
        let data = try JSONEncoder().encode(SHOCRBackend.ocrmypdf)
        let decoded = try JSONDecoder().decode(SHOCRBackend.self, from: data)
        #expect(decoded == .ocrmypdf)
    }
```

- [ ] **Step 2: Ověř selhání.** Run `...SHToolingTests/ocrBackendOcrmypdfExposesTitleAndIsCodable`. Expected: FAIL — „has no member 'ocrmypdf'".

- [ ] **Step 3: Přidej case.** V `enum SHOCRBackend` přidej za `case appleVisionThenOpenAI`:
```swift
    /// Lokální OCR přes ocrmypdf (tesseract). Fallback na Apple Vision při chybě.
    case ocrmypdf
```
a do `var title` switch:
```swift
        case .ocrmypdf: return "ocrmypdf"
```

- [ ] **Step 4: Ověř.** Run test. Expected: PASS. (Přidání case je zpětně kompatibilní — staré uložené hodnoty dál dekódují.)

- [ ] **Step 5: Commit.**
```bash
git add SpiceHarvester/Models/SHAppConfig.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "Config: OCR backend ocrmypdf"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 4: Zapojení do `makeOCRProvider` + signatura

**Files:** Modify `SpiceHarvester/ViewModels/SHAppViewModel.swift`

> `makeOCRProvider()` je `throws` switch; přidej exhaustivní case. `preprocessingSignature()` dostane case. Tool signatura zahrne ocrmypdf/tesseract když je backend ocrmypdf.

- [ ] **Step 1: Lokalizuj.**
```bash
grep -n "case .appleVisionThenOpenAI:\|func makeOCRProvider\|func preprocessingSignature\|signatureComponent(for:" SpiceHarvester/ViewModels/SHAppViewModel.swift
```

- [ ] **Step 2: Přidej case do `makeOCRProvider()`.** Za blok `case .appleVisionThenOpenAI:` (který končí `return SHFallbackOCRProvider(...)`) přidej:
```swift
        case .ocrmypdf:
            // Lokální OCR; když ocrmypdf chybí nebo selže, fallback na Apple Vision.
            return SHFallbackOCRProvider(primary: SHOcrmypdfProvider(), fallback: SHVisionOCRProvider())
```

- [ ] **Step 3: Přidej case do `preprocessingSignature()`.** Do switche nad `config.ocrBackend` přidej:
```swift
        case .ocrmypdf:
            return "ocr=ocrmypdf"
```

- [ ] **Step 4: Rozšiř tool signaturu.** V konstrukci pipeline (řádky ~2493) nahraď podmínku:
```swift
            if config.officeConversionEnabled || config.popplerPDFTextEnabled || config.spreadsheetConversionEnabled {
                let toolSignature = await SHToolRegistry().signatureComponent(for: [.pandoc, .pdftotext, .in2csv])
                preprocessSignature += "|tools:" + toolSignature
            }
```
za:
```swift
            var signatureTools: [SHTool] = []
            if config.officeConversionEnabled { signatureTools.append(.pandoc) }
            if config.popplerPDFTextEnabled { signatureTools.append(.pdftotext) }
            if config.spreadsheetConversionEnabled { signatureTools.append(.in2csv) }
            if config.ocrBackend == .ocrmypdf { signatureTools.append(contentsOf: [.ocrmypdf, .tesseract]) }
            if !signatureTools.isEmpty {
                let toolSignature = await SHToolRegistry().signatureComponent(for: signatureTools)
                preprocessSignature += "|tools:" + toolSignature
            }
```

- [ ] **Step 5: Build + testy.**
```bash
xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Release -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
xcodebuild test -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Debug -destination 'platform=macOS' -only-testing:SpiceHarvesterTests CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```
Expected: build OK (switch je nově exhaustivní), testy PASS.

- [ ] **Step 6: Commit.**
```bash
git add SpiceHarvester/ViewModels/SHAppViewModel.swift
git commit -m "OCR: zapoj ocrmypdf backend s fallbackem na Vision a do cache signatury"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 5: Settings — stav ocrmypdf/tesseract + footer pickeru

**Files:** Modify `SpiceHarvester/Views/SettingsView.swift`

> Picker už iteruje `SHOCRBackend.allCases`, takže „ocrmypdf" se v něm objeví automaticky. Doplníme jen stavové řádky nástrojů a text footeru.

- [ ] **Step 1: `@State`.** Přidej vedle ostatních status states:
```swift
    @State private var ocrmypdfStatusText = "Zjišťuji…"
    @State private var tesseractStatusText = "Zjišťuji…"
```

- [ ] **Step 2: Status řádky.** Do sekce „Lokální nástroje" v `ocrTab` za `LabeledContent("in2csv")` přidej:
```swift
                LabeledContent("ocrmypdf") {
                    Text(ocrmypdfStatusText).foregroundStyle(.secondary)
                }
                LabeledContent("tesseract") {
                    Text(tesseractStatusText).foregroundStyle(.secondary)
                }
```

- [ ] **Step 3: `.task`.** Do existujícího `.task` bloku v `ocrTab` přidej:
```swift
            ocrmypdfStatusText = Self.toolStatusLabel(await registry.status(for: .ocrmypdf))
            tesseractStatusText = Self.toolStatusLabel(await registry.status(for: .tesseract))
```

- [ ] **Step 4: Footer OCR backend pickeru.** V sekci „OCR backend" (footer Text) doplň na konec stávajícího textu větu:
```
 ocrmypdf je lokální OCR (tesseract) bez AI serveru; když není k dispozici, použije se Apple Vision.
```
(Vlož ji do existujícího `Text("…")` footeru jako pokračování — dodrž české uvozovky `„…"`, žádné rovné `"` uvnitř Swift stringu.)

- [ ] **Step 5: Keywords.** V `enum SettingsTab` u `case .ocr` přidej do `searchKeywords`: `"ocrmypdf"`, `"tesseract"`, `"sken"`.

- [ ] **Step 6: Release build + test.**
```bash
xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Release -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
xcodebuild test -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Debug -destination 'platform=macOS' -only-testing:SpiceHarvesterTests CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`, testy PASS. Pozn.: jde-li build s chybou „unable to type-check this expression in reasonable time" v Section builderu, vyčleň stavové řádky do `@ViewBuilder private var ocrToolRows: some View { ... }` a referencuj — nahlas, že jsi to udělal.

- [ ] **Step 7: Commit.**
```bash
git add SpiceHarvester/Views/SettingsView.swift
git commit -m "Settings: stav ocrmypdf/tesseract a popis OCR backendu"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 6: Packaging — bundle ocrmypdf + ghostscript + tesseract

**Files:** Create `scripts/bundle_ocr_tools.sh`

> Staví na bundlovaném Pythonu z Fáze 2 (`Contents/Helpers/python`). Doinstaluje ocrmypdf a zkopíruje `gs` + `tesseract` + `tessdata` + dylibs. Nelze plně spustit (vyžaduje `dylibbundler` a existující bundle); ověřuje se SYNTAX a graceful chování. Xcode wiring je manuální (pbxproj se needituje). ghostscript je **AGPL** — poznámka do licencí.

- [ ] **Step 1: Vytvoř `scripts/bundle_ocr_tools.sh`:**
```bash
#!/usr/bin/env bash
# Doinstaluje ocrmypdf do bundlovaného Pythonu (Contents/Helpers/python z Fáze 2)
# a zkopíruje ghostscript (gs), tesseract a tessdata (jen 5 jazyků) + dylibs do
# Contents/Helpers/. Spouští se jako Xcode Run Script phase (po bundle_python_tools.sh)
# nebo ručně: ./scripts/bundle_ocr_tools.sh /cesta/SpiceHarvester.app "-"
#
# POZNÁMKA: ghostscript je licencován pod AGPL — uveď to v licenčních podmínkách aplikace.
set -euo pipefail

APP="${1:-${CODESIGNING_FOLDER_PATH:?chybí cesta k .app}}"
SIGN_ID="${2:-${EXPANDED_CODE_SIGN_IDENTITY:--}}"
HELPERS="$APP/Contents/Helpers"
PYDIR="$HELPERS/python"
LIBS="$HELPERS/lib"
TESSDATA_DST="$HELPERS/tessdata"
LANGS=(ces slk deu pol eng osd)

command -v dylibbundler >/dev/null || { echo "chybí dylibbundler (brew install dylibbundler)"; exit 1; }
[ -x "$PYDIR/bin/python3" ] || { echo "chybí bundlovaný Python — spusť nejdřív bundle_python_tools.sh"; exit 1; }

# 1) ocrmypdf do bundlovaného Pythonu (jen pokud chybí)
if ! "$PYDIR/bin/python3" -c "import ocrmypdf" >/dev/null 2>&1; then
  "$PYDIR/bin/python3" -m pip install --no-warn-script-location ocrmypdf
fi
# wrapper ocrmypdf: PATH ať najde bundlovaný gs/tesseract, TESSDATA_PREFIX ať
# tesseract 5 najde bundlovaná tessdata
cat > "$HELPERS/ocrmypdf" <<'WRAP'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR:$PATH"
export TESSDATA_PREFIX="$DIR/tessdata"
exec "$DIR/python/bin/python3" -m ocrmypdf "$@"
WRAP
chmod +x "$HELPERS/ocrmypdf"

# 2) zkopíruj gs a tesseract binárky + dylibs
bundle_bin() {
  local name="$1"
  local src; src="$(command -v "$name")" || { echo "nenalezeno: $name"; exit 1; }
  cp -f "$src" "$HELPERS/$name"
  dylibbundler -of -b -x "$HELPERS/$name" -d "$LIBS" -p "@executable_path/lib"
}
bundle_bin gs
bundle_bin tesseract

# 3) tessdata jen pro vybrané jazyky
src_tessdata="$(dirname "$(command -v tesseract)")/../share/tessdata"
mkdir -p "$TESSDATA_DST"
for lang in "${LANGS[@]}"; do
  [ -f "$src_tessdata/$lang.traineddata" ] && cp -f "$src_tessdata/$lang.traineddata" "$TESSDATA_DST/"
done

# 4) podepiš dylibs (nemají +x), pak spustitelné a wrappery (hardened runtime)
if [ -d "$LIBS" ]; then
  find "$LIBS" -type f -name '*.dylib' -exec \
    codesign --force --options runtime --timestamp=none -s "$SIGN_ID" {} \;
fi
find "$HELPERS" -maxdepth 1 -type f -perm -u+x -exec \
  codesign --force --options runtime --timestamp=none -s "$SIGN_ID" {} \;

echo "Hotovo: ocrmypdf + gs + tesseract + tessdata v $HELPERS"
```

- [ ] **Step 2: Zpřístupni.**
```bash
chmod +x scripts/bundle_ocr_tools.sh
```

- [ ] **Step 3: Syntax.**
```bash
bash -n scripts/bundle_ocr_tools.sh && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`.

- [ ] **Step 4: Graceful chování.** Run (bez dylibbundler nebo bez bundlovaného Pythonu musí selhat s čitelnou hláškou, exit != 0, bez práce):
```bash
./scripts/bundle_ocr_tools.sh /tmp/x-$RANDOM.app "-" ; echo "exit=$?"
```
Zaznamenej hlášku + exit. (Buď „chybí dylibbundler", nebo „chybí bundlovaný Python".)

- [ ] **Step 5: Commit.**
```bash
git add scripts/bundle_ocr_tools.sh
git commit -m "Packaging: skript pro bundle ocrmypdf, ghostscript a tesseract"
python3 scripts/check_contributor_hygiene.py
```

- [ ] **Step 6: Zdokumentuj manuální krok** (NEPROVÁDĚJ — nahlas v reportu): do Xcode Run Script fáze přidat třetí řádek `"${SRCROOT}/scripts/bundle_ocr_tools.sh"` (PO `bundle_python_tools.sh`). Vyžaduje `brew install dylibbundler tesseract ghostscript ocrmypdf` na build stroji. ghostscript je AGPL → doplnit do licencí aplikace. Před notarizací přepnout `--timestamp=none` → `--timestamp` ve všech třech skriptech.

---

### Task 7: Dokumentace + finální build/test

**Files:** Modify `README.md`, `docs/KODOVA_DOKUMENTACE.md`

> `check_czech_quotes.py` lintuje jen `.swift`; `check_contributor_hygiene.py` skenuje i README. Neměň chráněné fráze (`macOS 15.6+`, `Výchozí režim aplikace je **SEARCH**.`, `PDF soubory nebo jinými typy souborů`, `SPARK DGX`); nepřidávej zakázané řetězce.

- [ ] **Step 1: README — Režimy/OCR.** V sekci „## Jak funguje pipeline" v kroku **Předzpracování** doplň additivně zmínku, že skenovaná PDF lze OCRovat lokálně přes ocrmypdf (tesseract) jako volitelný OCR backend. (Additivní úprava, chráněné fráze nech být.)

- [ ] **Step 2: KODOVA_DOKUMENTACE.md.** Do sekce „Konverzní vrstva (lokální CLI nástroje)" přidej odstavec:
```markdown
Skenovaná PDF (bez textové vrstvy) lze OCRovat lokálně přes `ocrmypdf` (tesseract + ghostscript) — `SHOcrmypdfProvider` implementuje `SHOCRProviding` a vybírá se OCR backendem `ocrmypdf`; při chybě nebo nedostupnosti nástroje se přes `SHFallbackOCRProvider` použije Apple Vision. Jazyky `ces+slk+deu+pol+eng`. Packaging bundluje ocrmypdf (do Pythonu), ghostscript (AGPL) a tesseract + `tessdata` přes `scripts/bundle_ocr_tools.sh`.
```

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
git commit -m "Docs: zdokumentuj lokální OCR skenů přes ocrmypdf"
python3 scripts/check_contributor_hygiene.py
```

---

## Hotová Fáze 3 znamená

- Uživatel může vybrat OCR backend **ocrmypdf** → skenovaná PDF se OCRují lokálně (tesseract, jazyky `ces+slk+deu+pol+eng`).
- Chybějící ocrmypdf nikdy neshodí běh — fallback na Apple Vision.
- Stav ocrmypdf/tesseract je v Settings; verze vstupují do cache signatury (při backendu ocrmypdf).
- Skript pro bundle ocrmypdf + ghostscript + tesseract existuje (Xcode wiring + závislosti = manuální krok; ghostscript AGPL).

## Společné dořešit po všech fázích (backlog)

- ✅ **Timestamp pro notarizaci** — `bundle_*.sh` odvozují codesign flag podle identity: ad-hoc (`-`) → `--timestamp=none`, Developer ID → `--timestamp`. Notarizace tak timestamp dostane automaticky, bez ruční editace.
- ✅ **ghostscript AGPL** — licenční sekce v aplikaci (Předvolby → OCR → Licence třetích stran) + [docs/LICENCE_TRETI_STRANY.md](../../LICENCE_TRETI_STRANY.md).
- ✅ **Konfigurovatelné OCR jazyky a timeout ocrmypdf** — `SHAppConfig.ocrLanguages` / `ocrTimeoutSeconds`, UI v Předvolby → OCR → „OCR ocrmypdf". Jazyky vstupují do cache signatury.
