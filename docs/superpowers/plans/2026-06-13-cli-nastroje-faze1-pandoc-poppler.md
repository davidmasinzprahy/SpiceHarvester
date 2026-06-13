# CLI nástroje — Fáze 1 (pandoc + poppler) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Přidat konverzní vrstvu, která přes bundlované CLI nástroje (pandoc, poppler) rozšíří vstupy o office dokumenty a nabídne opt-in lepší extrakci PDF textu — pod App Sandboxem, s graceful fallbackem na nativní cestu.

**Architecture:** Tři nové, izolovaně testovatelné komponenty (`SHToolRuntime` spouští binárky, `SHToolRegistry` detekuje dostupnost/verzi, `SHDocumentConverter` routuje soubor → nástroj → `SHPDFParseResult`). Čistá rozhodovací/parsovací logika je oddělená od skutečného `Process` execu, takže unit testy jsou deterministické a běží i v sandboxovaném CI; exec se ověřuje integračními testy gated na dostupnosti nástroje. Converter se zapojí do `SHPreprocessingPipeline.parseText` a při chybějícím nástroji vrací `nil` → použije se stávající PDFKit/text cesta.

**Tech Stack:** Swift 5, Foundation `Process`, Swift Testing (`import Testing`), Xcode 16, xcodebuild.

---

## Referenční dokument

Spec: `docs/superpowers/specs/2026-06-13-cli-nastroje-vytezovani-design.md`

## Konvence pro tento repozitář (DŮLEŽITÉ)

- **Commity bez jakékoli Claude atribuce.** Žádné `Co-Authored-By`, žádné `Claude`, žádné `noreply@anthropic.com` — `scripts/check_contributor_hygiene.py` skenuje celou historii a shodí CI. Autor/committer musí být `davidmasinzprahy <david.masin@gmail.com>`.
- **Commituj přímo na `main`** (žádná feature větev).
- Po každém commitu spusť `python3 scripts/check_contributor_hygiene.py` — musí vypsat `OK`.

## Test/build příkazy

Unit testy:
```bash
xcodebuild test \
  -project SpiceHarvester.xcodeproj \
  -scheme SpiceHarvester \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:SpiceHarvesterTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Konkrétní test (rychlá smyčka), nahraď `<NÁZEV>`:
```bash
xcodebuild test \
  -project SpiceHarvester.xcodeproj -scheme SpiceHarvester \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:SpiceHarvesterTests/SpiceHarvesterTests/<NÁZEV> \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Release build:
```bash
xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester \
  -configuration Release -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

## Xcode target membership (platí pro KAŽDÝ nový `.swift` soubor)

Nové soubory pod `SpiceHarvester/Services/` musí být přidány do targetu `SpiceHarvester`, jinak je `xcodebuild` nezkompiluje a `@testable import SpiceHarvester` je v testech neuvidí. Po vytvoření souboru ho přidej do targetu (v Xcode přetažením / „Add Files…", nebo editací `SpiceHarvester.xcodeproj/project.pbxproj`). Každý implementační krok níže, který vytváří soubor, na to znovu upozorní.

## Mapa souborů

- Create: `SpiceHarvester/Services/SHTool.swift` — enum nástrojů + `SHToolResult` + chyby
- Create: `SpiceHarvester/Services/SHToolRuntime.swift` — resolve cesty + `Process` exec
- Create: `SpiceHarvester/Services/SHToolRegistry.swift` — detekce dostupnosti/verze + cache signatura
- Create: `SpiceHarvester/Services/SHDocumentConverter.swift` — routing + konverze na `SHPDFParseResult`
- Modify: `SpiceHarvester/Services/SHFileScanService.swift:5-14` — rozšířit přípony
- Modify: `SpiceHarvester/Models/SHAppConfig.swift` — přidat přepínače `officeConversionEnabled`, `popplerPDFTextEnabled`
- Modify: `SpiceHarvester/Pipeline/SHPreprocessingPipeline.swift` — zapojit converter do `parseText`
- Modify: konstrukce `SHPreprocessingPipeline(...)` (najdi grepem) — přidat verze nástrojů do `preprocessingSignature`
- Modify: `SpiceHarvester/Views/SettingsView.swift` — panel se stavem nástrojů + přepínači
- Create: `scripts/bundle_tools.sh` — vendor pandoc + poppler binárek a dylibs do bundle
- Test: `SpiceHarvesterTests/SHToolingTests.swift` — nový test soubor pro Fázi 1
- Modify: `README.md` + `docs/KODOVA_DOKUMENTACE.md` — zdokumentovat nové vstupní formáty

---

### Task 1: Typy nástrojů (`SHTool`, `SHToolResult`, chyby)

**Files:**
- Create: `SpiceHarvester/Services/SHTool.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

- [ ] **Step 1: Napiš padající test**

Vytvoř `SpiceHarvesterTests/SHToolingTests.swift`:
```swift
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
}
```

- [ ] **Step 2: Přidej testovací soubor do targetu `SpiceHarvesterTests`** (viz sekce „Xcode target membership"), pak ověř, že test selže na chybějícím typu.

Run: viz „Unit testy". Expected: FAIL / build error „cannot find 'SHTool' in scope".

- [ ] **Step 3: Vytvoř `SHTool.swift`**

```swift
import Foundation

/// Externí CLI nástroje volané z aplikace. `rawValue` == název spustitelného souboru.
enum SHTool: String, CaseIterable, Sendable {
    case pandoc
    case pdftotext
    case pdfinfo

    var executableName: String { rawValue }
    var versionArguments: [String] { ["--version"] }
}

/// Výsledek spuštění nástroje.
struct SHToolResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum SHToolError: Error, Sendable {
    case notFound(SHTool)
    case timedOut(SHTool)
    case nonZeroExit(SHTool, code: Int32, stderr: String)
}
```

- [ ] **Step 4: Přidej `SHTool.swift` do targetu `SpiceHarvester`**, pak spusť test.

Run: viz „Unit testy". Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/Services/SHTool.swift SpiceHarvesterTests/SHToolingTests.swift SpiceHarvester.xcodeproj/project.pbxproj
git commit -m "Tooling: zaveď SHTool, SHToolResult a SHToolError"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 2: `SHToolRuntime.resolve` (čistá logika hledání binárky)

**Files:**
- Create: `SpiceHarvester/Services/SHToolRuntime.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

- [ ] **Step 1: Napiš padající test** (přidej metodu do `SHToolingTests`)

```swift
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
```

- [ ] **Step 2: Ověř selhání**

Run: `...SHToolingTests/runtimeResolvesFromHelpersThenPath`. Expected: FAIL — „cannot find 'SHToolRuntime'".

- [ ] **Step 3: Vytvoř `SHToolRuntime.swift`** (zatím jen resolve + inicializace)

```swift
import Foundation

struct SHToolRuntime: Sendable {
    let helpersDirectory: URL?
    let pathDirectories: [URL]

    init(
        helpersDirectory: URL? = SHToolRuntime.defaultHelpersDirectory,
        pathDirectories: [URL] = SHToolRuntime.defaultPathDirectories
    ) {
        self.helpersDirectory = helpersDirectory
        self.pathDirectories = pathDirectories
    }

    /// Bundlovaná binárka má přednost před PATH (PATH je jen vývojová pohodlnost).
    func resolve(_ tool: SHTool) -> URL? {
        let fm = FileManager.default
        if let helpers = helpersDirectory {
            let candidate = helpers.appendingPathComponent(tool.executableName)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        for dir in pathDirectories {
            let candidate = dir.appendingPathComponent(tool.executableName)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static var defaultHelpersDirectory: URL? {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    static var defaultPathDirectories: [URL] {
        let raw = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return raw.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }
}
```

- [ ] **Step 4: Přidej soubor do targetu, spusť test.** Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/Services/SHToolRuntime.swift SpiceHarvesterTests/SHToolingTests.swift SpiceHarvester.xcodeproj/project.pbxproj
git commit -m "Tooling: SHToolRuntime resolve (helpers -> PATH)"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 3: `SHToolRuntime.run` (skutečný `Process` exec)

**Files:**
- Modify: `SpiceHarvester/Services/SHToolRuntime.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

> Poznámka: exec se v sandboxovaném test hostu nemusí v CI povolit pro systémové binárky. Proto je tento test **integrační** a sám se přeskočí, když nástroj není dostupný — neblokuje CI.

- [ ] **Step 1: Napiš integrační test**
```swift
    @Test func runtimeRunsPandocVersionWhenAvailable() async throws {
        let runtime = SHToolRuntime()
        guard runtime.resolve(.pandoc) != nil else { return } // přeskoč, není-li pandoc
        let result = try await runtime.run(.pandoc, arguments: ["--version"], timeout: 30)
        #expect(result.exitCode == 0)
        #expect(result.stdoutString.lowercased().contains("pandoc"))
    }
```

- [ ] **Step 2: Ověř selhání**

Run: `...SHToolingTests/runtimeRunsPandocVersionWhenAvailable`. Expected: FAIL — „value of type 'SHToolRuntime' has no member 'run'".

- [ ] **Step 3: Doplň `run` do `SHToolRuntime`**

```swift
    func run(
        _ tool: SHTool,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 120
    ) async throws -> SHToolResult {
        guard let executable = resolve(tool) else { throw SHToolError.notFound(tool) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SHToolResult, Error>) in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments

                let outPipe = Pipe(); let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let inPipe = Pipe()
                if stdin != nil { process.standardInput = inPipe }

                let timeoutItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                process.terminationHandler = { proc in
                    timeoutItem.cancel()
                    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                    // SIGTERM z timeoutu => uncaughtSignal
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: SHToolError.timedOut(tool))
                    } else {
                        continuation.resume(returning: SHToolResult(exitCode: proc.terminationStatus, stdout: out, stderr: err))
                    }
                }

                do {
                    try process.run()
                    if let stdin {
                        inPipe.fileHandleForWriting.write(stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }
                } catch {
                    timeoutItem.cancel()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // nejlepší snaha: nic dalšího nemáme bez reference na proces mimo continuation
        }
    }
```

- [ ] **Step 4: Spusť test.** Expected: PASS, pokud je pandoc v PATH; jinak se test tiše vrátí (přeskočí) a stále projde.

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/Services/SHToolRuntime.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "Tooling: SHToolRuntime.run s timeoutem a capture stdout/stderr"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 4: `SHToolRegistry` (detekce verze + cache signatura)

**Files:**
- Create: `SpiceHarvester/Services/SHToolRegistry.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

- [ ] **Step 1: Napiš padající test čistého parseru verze**
```swift
    @Test func parseVersionExtractsSemverFromOutput() {
        #expect(SHToolRegistry.parseVersion(from: "pandoc 3.1.9\nFeatures...") == "3.1.9")
        #expect(SHToolRegistry.parseVersion(from: "pdftotext version 24.04.0") == "24.04.0")
        #expect(SHToolRegistry.parseVersion(from: "no version here") == nil)
    }
```

- [ ] **Step 2: Ověř selhání**

Run: `...SHToolingTests/parseVersionExtractsSemverFromOutput`. Expected: FAIL — „cannot find 'SHToolRegistry'".

- [ ] **Step 3: Vytvoř `SHToolRegistry.swift`**

```swift
import Foundation

actor SHToolRegistry {
    enum Status: Sendable, Equatable {
        case available(version: String)
        case missing
    }

    private let runtime: SHToolRuntime
    private var cache: [SHTool: Status] = [:]

    init(runtime: SHToolRuntime = SHToolRuntime()) {
        self.runtime = runtime
    }

    func status(for tool: SHTool) async -> Status {
        if let cached = cache[tool] { return cached }
        let resolved: Status
        if runtime.resolve(tool) == nil {
            resolved = .missing
        } else if let result = try? await runtime.run(tool, arguments: tool.versionArguments, timeout: 15),
                  result.exitCode == 0 {
            let merged = result.stdoutString + "\n" + result.stderrString
            resolved = .available(version: Self.parseVersion(from: merged) ?? "neznámá")
        } else {
            resolved = .missing
        }
        cache[tool] = resolved
        return resolved
    }

    /// Stabilní řetězec verzí pro cache signaturu. Změna verze nástroje invaliduje cache.
    func signatureComponent(for tools: [SHTool]) async -> String {
        var parts: [String] = []
        for tool in tools.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch await status(for: tool) {
            case .available(let version): parts.append("\(tool.rawValue)=\(version)")
            case .missing: parts.append("\(tool.rawValue)=missing")
            }
        }
        return parts.joined(separator: ";")
    }

    /// Čistá funkce: první výskyt `N.N` nebo `N.N.N` ve výstupu `--version`.
    static func parseVersion(from output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }
}
```

- [ ] **Step 4: Přidej soubor do targetu, spusť test.** Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/Services/SHToolRegistry.swift SpiceHarvesterTests/SHToolingTests.swift SpiceHarvester.xcodeproj/project.pbxproj
git commit -m "Tooling: SHToolRegistry s detekcí verze a cache signaturou"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 5: `SHDocumentConverter.route` (čisté rozhodnutí o cestě)

**Files:**
- Create: `SpiceHarvester/Services/SHDocumentConverter.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

- [ ] **Step 1: Napiš padající test**
```swift
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
```

- [ ] **Step 2: Ověř selhání**

Run: `...SHToolingTests/converterRoutingByExtension`. Expected: FAIL — „cannot find 'SHDocumentConverter'".

- [ ] **Step 3: Vytvoř `SHDocumentConverter.swift`** (zatím jen typ + `route`)

```swift
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
```

- [ ] **Step 4: Přidej soubor do targetu, spusť test.** Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/Services/SHDocumentConverter.swift SpiceHarvesterTests/SHToolingTests.swift SpiceHarvester.xcodeproj/project.pbxproj
git commit -m "Converter: routing souborů podle přípony (pandoc/poppler/native)"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 6: `SHDocumentConverter.convert` (pandoc + poppler exec)

**Files:**
- Modify: `SpiceHarvester/Services/SHDocumentConverter.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

> Vrací `SHPDFParseResult?` — `nil` znamená „použij nativní cestu". Pro `.popplerText` se výstup `pdftotext` dělí na stránky podle form-feed `\u{0C}`.

- [ ] **Step 1: Napiš integrační test** (gated na dostupnosti pandoc)
```swift
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
```

- [ ] **Step 2: Ověř selhání**

Run: `...SHToolingTests/converterReturnsNilForNativeRoute`. Expected: FAIL — „no member 'convert'".

- [ ] **Step 3: Doplň `convert` do `SHDocumentConverter`**

```swift
    /// Vrátí normalizovaný výsledek, nebo `nil` pro nativní cestu / při chybějícím nástroji.
    func convert(fileURL: URL, popplerPDFTextEnabled: Bool) async -> SHPDFParseResult? {
        switch Self.route(for: fileURL, popplerPDFTextEnabled: popplerPDFTextEnabled) {
        case .native:
            return nil
        case .pandoc:
            return await runPandoc(fileURL)
        case .popplerText:
            return await runPdftotext(fileURL)
        }
    }

    private func runPandoc(_ fileURL: URL) async -> SHPDFParseResult? {
        guard runtime.resolve(.pandoc) != nil else { return nil }
        guard let result = try? await runtime.run(.pandoc, arguments: ["-t", "plain", fileURL.path], timeout: 120),
              result.exitCode == 0 else { return nil }
        let text = result.stdoutString
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHPDFParseResult(rawPages: [text], hasTextLayer: !trimmed.isEmpty, pageCount: 1)
    }

    private func runPdftotext(_ fileURL: URL) async -> SHPDFParseResult? {
        guard runtime.resolve(.pdftotext) != nil else { return nil }
        // `-layout` zachová sloupce; `-` posílá výstup na stdout
        guard let result = try? await runtime.run(.pdftotext, arguments: ["-layout", fileURL.path, "-"], timeout: 120),
              result.exitCode == 0 else { return nil }
        let pages = result.stdoutString.components(separatedBy: "\u{0C}")
        let nonEmpty = pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return SHPDFParseResult(rawPages: pages, hasTextLayer: nonEmpty, pageCount: pages.count)
    }
```

- [ ] **Step 4: Spusť testy.** Expected: `converterReturnsNilForNativeRoute` PASS; `converterPandocReadsHtmlWhenAvailable` PASS (nebo přeskočen bez pandoc).

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/Services/SHDocumentConverter.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "Converter: konverze přes pandoc a pdftotext na SHPDFParseResult"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 7: Rozšíření podporovaných přípon ve skeneru

**Files:**
- Modify: `SpiceHarvester/Services/SHFileScanService.swift:5-14`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

- [ ] **Step 1: Napiš padající test**
```swift
    @Test func scannerSupportsOfficeAndSpreadsheetExtensions() {
        let ext = SHFileScanService.supportedDocumentExtensions
        for e in ["docx", "odt", "rtf", "html", "htm", "epub", "xlsx", "xls"] {
            #expect(ext.contains(e), "chybí přípona \(e)")
        }
        // stávající nesmí zmizet
        #expect(ext.contains("pdf"))
        #expect(ext.contains("txt"))
    }
```

- [ ] **Step 2: Ověř selhání**

Run: `...SHToolingTests/scannerSupportsOfficeAndSpreadsheetExtensions`. Expected: FAIL na chybějícím `docx`.

- [ ] **Step 3: Rozšiř množinu**

V `SHFileScanService.swift` nahraď `supportedDocumentExtensions` za:
```swift
    static let supportedDocumentExtensions: Set<String> = [
        "pdf",
        "txt",
        "text",
        "md",
        "markdown",
        "csv",
        "tsv",
        "json",
        // office (pandoc, Fáze 1)
        "docx",
        "odt",
        "rtf",
        "html",
        "htm",
        "epub",
        // tabulky (csvkit, Fáze 2 — sken už je hledá, konverze přijde s Fází 2)
        "xlsx",
        "xls"
    ]
```

- [ ] **Step 4: Spusť test.** Expected: PASS.

> Pozn.: existující test `fileScannerFindsSupportedDocumentsAndSkipsHiddenOrUnsupportedFiles` používá jen pdf/txt/md/csv/json a `image.png` (nepodporované) — rozšíření ho neporuší.

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/Services/SHFileScanService.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "Scan: rozšiř podporované vstupy o office a tabulkové formáty"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 8: Přepínače v `SHAppConfig`

**Files:**
- Modify: `SpiceHarvester/Models/SHAppConfig.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

- [ ] **Step 1: Napiš padající test**
```swift
    @Test func appConfigToolingDefaultsAndCodableRoundtrip() throws {
        let config = SHAppConfig()
        #expect(config.officeConversionEnabled == true)
        #expect(config.popplerPDFTextEnabled == false)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SHAppConfig.self, from: data)
        #expect(decoded.officeConversionEnabled == true)
        #expect(decoded.popplerPDFTextEnabled == false)
    }
```

- [ ] **Step 2: Ověř selhání**

Run: `...SHToolingTests/appConfigToolingDefaultsAndCodableRoundtrip`. Expected: FAIL — „value of type 'SHAppConfig' has no member 'officeConversionEnabled'".

- [ ] **Step 3: Přidej pole + Codable podporu**

V `SHAppConfig.swift` přidej za `var lastLoadedPromptName` (řádek ~122) tyto property:
```swift
    /// Konverze office dokumentů (docx/odt/rtf/html/epub) přes pandoc. Default zapnuto.
    var officeConversionEnabled: Bool = true
    /// Extrakce textu z PDF přes `pdftotext -layout` místo PDFKit. Default vypnuto (opt-in).
    var popplerPDFTextEnabled: Bool = false
```

Do `enum CodingKeys` přidej:
```swift
        case officeConversionEnabled, popplerPDFTextEnabled
```

V `init(from:)` přidej (před uzavírací `}`):
```swift
        officeConversionEnabled = try c.decodeIfPresent(Bool.self, forKey: .officeConversionEnabled) ?? true
        popplerPDFTextEnabled = try c.decodeIfPresent(Bool.self, forKey: .popplerPDFTextEnabled) ?? false
```

- [ ] **Step 4: Spusť test.** Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/Models/SHAppConfig.swift SpiceHarvesterTests/SHToolingTests.swift
git commit -m "Config: přepínače officeConversionEnabled a popplerPDFTextEnabled"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 9: Zapojení converteru do `SHPreprocessingPipeline`

**Files:**
- Modify: `SpiceHarvester/Pipeline/SHPreprocessingPipeline.swift`
- Test: `SpiceHarvesterTests/SHToolingTests.swift`

> `parseText` se stane `async` a nejdřív zkusí converter; vrátí-li `nil`, použije stávající PDFKit/UTF-8 cestu. Converter a přepínače se injektují přes init (default zachovává staré chování).

- [ ] **Step 1: Napiš padající test** — converter má přednost, nativní fallback funguje

```swift
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
```

> `NoopOCRProvider` je definovaný v `SpiceHarvesterTests.swift`. Aby byl viditelný i z `SHToolingTests.swift`, přesuň jeho deklaraci z `private struct` na `struct NoopOCRProvider` (odebrat `private`) v `SpiceHarvesterTests.swift`, ať ho sdílí oba test soubory v rámci modulu.

- [ ] **Step 2: Ověř selhání**

Run: `...SHToolingTests/pipelineUsesConverterThenFallsBackToNative`. Expected: FAIL — init nemá parametr `converter`.

- [ ] **Step 3: Uprav `SHPreprocessingPipeline`**

V `SHPreprocessingPipeline` přidej uložené vlastnosti a parametry initu:
```swift
    private let converter: SHDocumentConverter
    private let officeConversionEnabled: Bool
    private let popplerPDFTextEnabled: Bool
```
Init signatura — přidej na začátek (před `ocrProvider`) parametry s defaulty, ať existující volání nepadnou:
```swift
    init(
        converter: SHDocumentConverter = SHDocumentConverter(),
        officeConversionEnabled: Bool = false,
        popplerPDFTextEnabled: Bool = false,
        ocrProvider: SHOCRProviding,
        cacheManager: SHCacheManager,
        logger: SHProcessingLogger,
        benchmark: SHBenchmarkService,
        maxConcurrentWorkers: Int,
        preprocessingSignature: String = ""
    ) {
        self.converter = converter
        self.officeConversionEnabled = officeConversionEnabled
        self.popplerPDFTextEnabled = popplerPDFTextEnabled
        self.ocrProvider = ocrProvider
        // ... zbytek beze změny
```

Nahraď `parseText` za `async` variantu, která respektuje přepínače a converter:
```swift
    private func parseText(from fileURL: URL) async -> SHPDFParseResult {
        let ext = fileURL.pathExtension.lowercased()
        let officeExtension = SHDocumentConverter.pandocExtensions.contains(ext)

        // converter zkus jen když je relevantní a povolený
        let converterAllowed = (officeExtension && officeConversionEnabled)
            || (ext == "pdf" && popplerPDFTextEnabled)
        if converterAllowed,
           let converted = await converter.convert(fileURL: fileURL, popplerPDFTextEnabled: popplerPDFTextEnabled) {
            return converted
        }

        // nativní cesta (beze změny)
        if ext == "pdf" {
            return parser.parse(fileURL)
        }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return SHPDFParseResult(rawPages: [], hasTextLayer: false, pageCount: 0)
        }
        return SHPDFParseResult(
            rawPages: [text],
            hasTextLayer: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            pageCount: 1
        )
    }
```

Na jediném volání v `processOne` (řádek ~116) změň:
```swift
        let parsed = await parseText(from: fileURL)
```

- [ ] **Step 4: Spusť celý test soubor + existující pipeline test.** Expected: PASS (vč. `preprocessingPipelineReadsPlainTextDocumentsWithoutOCR`).

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/Pipeline/SHPreprocessingPipeline.swift SpiceHarvesterTests/SHToolingTests.swift SpiceHarvesterTests/SpiceHarvesterTests.swift
git commit -m "Pipeline: zapoj SHDocumentConverter s nativním fallbackem"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 10: Verze nástrojů v cache signatuře

**Files:**
- Modify: místo konstrukce `SHPreprocessingPipeline(...)` (najdi grepem)
- Modify: `SpiceHarvester/Pipeline/SHPreprocessingPipeline.swift` (žádná změna logiky `cacheHash`, jen předávaná signatura)

> Cíl: změna verze pandoc/pdftotext invaliduje dotčené dokumenty. `preprocessingSignature` se skládá tam, kde se pipeline vytváří.

- [ ] **Step 1: Najdi konstrukci pipeline**

Run:
```bash
grep -rn "SHPreprocessingPipeline(" SpiceHarvester --include='*.swift'
```
Expected: jeden výskyt v produkčním kódu (pravděpodobně `SpiceHarvester/ViewModels/SHAppViewModel.swift`).

- [ ] **Step 2: Předej converter, přepínače a tool signaturu**

V místě konstrukce (před voláním initu) získej signaturu a předej nové parametry. Příklad (uprav názvy proměnných podle okolního kódu — `config` je `SHAppConfig`, `registry` je `SHToolRegistry`):
```swift
let registry = SHToolRegistry()
let toolSignature = await registry.signatureComponent(for: [.pandoc, .pdftotext])
let pipeline = SHPreprocessingPipeline(
    converter: SHDocumentConverter(runtime: SHToolRuntime()),
    officeConversionEnabled: config.officeConversionEnabled,
    popplerPDFTextEnabled: config.popplerPDFTextEnabled,
    ocrProvider: ocrProvider,           // existující proměnná
    cacheManager: cacheManager,         // existující proměnná
    logger: logger,                     // existující proměnná
    benchmark: benchmark,               // existující proměnná
    maxConcurrentWorkers: config.maxConcurrentPDFWorkers,
    preprocessingSignature: existingSignature + "|tools:" + toolSignature
)
```
Pokud na daném místě dosud žádná `preprocessingSignature` není, použij `"tools:" + toolSignature`. Pokud kontext není `async`, obal získání signatury do okolního `Task`/`await` podle stávajícího vzoru ve `SHAppViewModel`.

- [ ] **Step 3: Build + testy**

Run: „Release build" a „Unit testy". Expected: build OK, testy PASS.

- [ ] **Step 4: Manuální ověření cache** (nepovinné)

Spusť pipeline nad vstupní složkou dvakrát za sebou. První běh zaloguje `CACHE miss` + `CACHE saved`, druhý běh `CACHE hit` — potvrzuje, že signatura (vč. `tools:` segmentu) je stabilní mezi běhy. Stačí ověřit v processing logu.

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/ViewModels/SHAppViewModel.swift
git commit -m "Pipeline: cache signatura zahrnuje verze CLI nástrojů"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 11: Settings panel — stav nástrojů + přepínače

**Files:**
- Modify: `SpiceHarvester/Views/SettingsView.swift`

> UI nemá unit testy; ověřuje se spuštěním aplikace. Drž se okolního stylu (sekce `Form`/`Section`, `GlassCard` apod.).

- [ ] **Step 1: Prozkoumej stávající strukturu**

Run:
```bash
grep -n "Section\|Toggle\|config\." SpiceHarvester/Views/SettingsView.swift | head -40
```

- [ ] **Step 2: Přidej sekci „Lokální nástroje"**

Do `SettingsView` přidej novou sekci (uprav vazbu na `config` podle okolního kódu — typicky `@Bindable`/`@Binding var config: SHAppConfig` nebo přes view model):
```swift
Section("Lokální nástroje") {
    Toggle("Konverze office dokumentů (pandoc)", isOn: $config.officeConversionEnabled)
    Toggle("Extrakce PDF textu přes pdftotext (-layout)", isOn: $config.popplerPDFTextEnabled)
    LabeledContent("pandoc") { Text(pandocStatusText) }
    LabeledContent("pdftotext") { Text(pdftotextStatusText) }
}
```
Stavové texty naplň přes `SHToolRegistry` v `.task { }` modifieru a ulož do `@State` (`@State private var pandocStatusText = "Zjišťuji…"`, `@State private var pdftotextStatusText = "Zjišťuji…"`):
```swift
.task {
    let registry = SHToolRegistry()
    pandocStatusText = Self.statusLabel(await registry.status(for: .pandoc))
    pdftotextStatusText = Self.statusLabel(await registry.status(for: .pdftotext))
}
```
Pomocná (čistá, neasync) funkce — `status(for:)` je `async`, ale `statusLabel` dostává už hotový `Status`:
```swift
private static func statusLabel(_ status: SHToolRegistry.Status) -> String {
    switch status {
    case .available(let v): return "k dispozici (\(v))"
    case .missing: return "není v aplikaci"
    }
}
```

- [ ] **Step 3: Build aplikace**

Run: „Release build". Expected: build OK.

- [ ] **Step 4: Manuální ověření**

Spusť schéma `SpiceHarvester` v Xcode, otevři Settings → sekce „Lokální nástroje" ukazuje stav pandoc/pdftotext a oba přepínače fungují (mění `config`, přežijí restart).

- [ ] **Step 5: Commit**
```bash
git add SpiceHarvester/Views/SettingsView.swift
git commit -m "Settings: sekce Lokální nástroje se stavem a přepínači"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 12: Packaging — bundle pandoc + poppler do `.app`

**Files:**
- Create: `scripts/bundle_tools.sh`
- Modify: Xcode „Run Script" build phase (přidá se v Xcode)

> Cílem je dostat podepsané binárky + jejich dylibs do `SpiceHarvester.app/Contents/Helpers/`. Toto nelze unit-testovat; ověřuje se `codesign` a spuštěním bundlované binárky. Vyžaduje `dylibbundler` (`brew install dylibbundler`).

- [ ] **Step 1: Vytvoř `scripts/bundle_tools.sh`**

```bash
#!/usr/bin/env bash
# Zkopíruje pandoc + poppler (pdftotext, pdfinfo) a jejich dylibs do
# <APP>/Contents/Helpers/ a opraví rpath. Spouští se jako Xcode Run Script phase
# (proměnné CODESIGNING_FOLDER_PATH, EXPANDED_CODE_SIGN_IDENTITY dodá Xcode),
# nebo ručně: ./scripts/bundle_tools.sh /cesta/SpiceHarvester.app "-"
set -euo pipefail

APP="${1:-${CODESIGNING_FOLDER_PATH:?chybí cesta k .app}}"
SIGN_ID="${2:-${EXPANDED_CODE_SIGN_IDENTITY:--}}"
HELPERS="$APP/Contents/Helpers"
LIBS="$HELPERS/lib"
mkdir -p "$HELPERS"

command -v dylibbundler >/dev/null || { echo "chybí dylibbundler (brew install dylibbundler)"; exit 1; }

bundle_one() {
  local name="$1"
  local src; src="$(command -v "$name")" || { echo "nenalezeno: $name"; exit 1; }
  cp -f "$src" "$HELPERS/$name"
  # vlož dylibs do Helpers/lib a přepiš odkazy na @executable_path/lib
  dylibbundler -of -b -x "$HELPERS/$name" -d "$LIBS" -p "@executable_path/lib"
}

for t in pandoc pdftotext pdfinfo; do bundle_one "$t"; done

# podepiš s hardened runtime, aby šly spustit pod sandboxem rodiče
find "$HELPERS" -type f -perm -u+x -exec \
  codesign --force --options runtime --timestamp=none -s "$SIGN_ID" {} \;

echo "Hotovo: nástroje v $HELPERS"
```

- [ ] **Step 2: Zpřístupni skript**
```bash
chmod +x scripts/bundle_tools.sh
```

- [ ] **Step 3: Přidej Run Script build phase v Xcode**

V Xcode → target `SpiceHarvester` → Build Phases → „+" → New Run Script Phase, umísti **za** „Copy Bundle Resources", tělo:
```bash
"${SRCROOT}/scripts/bundle_tools.sh"
```
Odškrtni „Based on dependency analysis" (skript běží vždy). Pozn.: Pokud cílíš jen Debug běh bez podpisu, lze fázi podmínit `if [ "$CONFIGURATION" = "Release" ]`.

- [ ] **Step 4: Ověření**

Run (po Release buildu, cesta k produktu se liší — najdi `.app` v DerivedData nebo `build/`):
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'SpiceHarvester.app' -type d 2>/dev/null | head -1)
ls "$APP/Contents/Helpers"
codesign -dv "$APP/Contents/Helpers/pandoc" 2>&1 | head -3
"$APP/Contents/Helpers/pandoc" --version | head -1
"$APP/Contents/Helpers/pdftotext" -v 2>&1 | head -1
```
Expected: vypíše `pandoc <verze>` a `pdftotext version <verze>`; binárky jsou podepsané.

- [ ] **Step 5: Commit**
```bash
git add scripts/bundle_tools.sh SpiceHarvester.xcodeproj/project.pbxproj
git commit -m "Packaging: bundle pandoc a poppler binárek do .app/Contents/Helpers"
python3 scripts/check_contributor_hygiene.py
```

---

### Task 13: Dokumentace + finální build/test

**Files:**
- Modify: `README.md`
- Modify: `docs/KODOVA_DOKUMENTACE.md`

> Pozor: `scripts/check_czech_quotes.py` lintuje české uvozovky — používej `„…"`, ne rovné `"`. Po editaci README spusť oba lint skripty.

- [ ] **Step 1: Doplň README — podporované vstupy**

V `README.md` v sekci „K čemu slouží" / pipeline doplň, že kromě PDF a textu umí aplikace přes bundlované nástroje i **office dokumenty (DOCX, ODT, RTF, HTML, EPUB přes pandoc)** a volitelně **přesnější PDF text přes pdftotext (`-layout`)**. Dodrž české uvozovky.

> Nepřidávej nic, co by obsahovalo zakázané řetězce (viz konvence). Existující test `readmeDoesNotRegressKnownDocumentationFacts` kontroluje konkrétní fráze — neodstraňuj je.

- [ ] **Step 2: Doplň `docs/KODOVA_DOKUMENTACE.md`**

Přidej krátkou sekci „Konverzní vrstva (CLI nástroje)" popisující `SHToolRuntime`, `SHToolRegistry`, `SHDocumentConverter`, bundlování do `Contents/Helpers` a fallback na nativní cestu.

- [ ] **Step 3: Lint dokumentace**
```bash
python3 scripts/check_czech_quotes.py
python3 scripts/check_contributor_hygiene.py
```
Expected: oba `OK`.

- [ ] **Step 4: Plný build + testy**

Run: „Release build" a „Unit testy". Expected: build OK; všechny testy PASS (vč. nového `SHToolingTests` a stávajících).

- [ ] **Step 5: Commit**
```bash
git add README.md docs/KODOVA_DOKUMENTACE.md
git commit -m "Docs: zdokumentuj konverzní vrstvu a nové vstupní formáty"
python3 scripts/check_contributor_hygiene.py
```

---

## Hotová Fáze 1 znamená

- Aplikace zpracuje DOCX/ODT/RTF/HTML/EPUB (pandoc) a volitelně PDF přes `pdftotext -layout`.
- Chybějící nástroj nikdy neshodí pipeline (fallback na PDFKit/UTF-8).
- Stav nástrojů a přepínače jsou v Settings; změna verze nástroje invaliduje cache.
- Binárky pandoc/poppler jsou bundlované a podepsané v `.app/Contents/Helpers/`.

## Navazující fáze (samostatné plány)

- **Fáze 2 — csvkit (XLSX/XLS → CSV):** přidat `SHTool.in2csv`, route `.csvkit`, bundlovat relocatable Python + `in2csv`. Sken už přípony `xlsx/xls` hledá od Fáze 1.
- **Fáze 3 — ocrmypdf + tesseract + ghostscript (OCR skenů):** nová OCR větev v converteru pro PDF bez textové vrstvy; bundlovat Python + ghostscript (AGPL — poznámka v licencích) + tesseract + `tessdata` (`ces, slk, deu, pol, eng`).
