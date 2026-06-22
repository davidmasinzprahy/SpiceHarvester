# DocumentGroup refactor — design

## Cíl

Transformovat Spice Harvester z single-window appky s live-UserDefaults
persistencí na **document-based** aplikaci postavenou na `DocumentGroup`. Tři
potvrzené cíle:

1. **Nativní document lifecycle** — autosave, verze, „modified" tečka v titulku, Cmd+S.
2. **Okno = jeden projekt** — každé okno svázané s konkrétním `.spiceharvester` dokumentem; File→New = prázdný projekt; nativní Open / Open Recent / drag-onto-icon.
3. **Čistší kód** — rozbití 3108řádkového `SHAppViewModel` na global vs per-document.

Plus dvě schválená sub-rozhodnutí:
- **(A)** App prefs (souběžnost, timeout, OCR backend, cache toggle, throttle, kontext modelu, conversion toggles) se přesouvají do **globálního** stavu (Settings je app-level).
- **(B)** AppIntents běží přes **Default Project** dokument (headless).

## Architektura

### `SHGlobalState` (`@MainActor @Observable final class`)
App-level singleton, vytvořený v `SpiceHarvesterApp` jako `@State`, injektovaný
do scén přes `.environment(...)`. Vlastní:
- **Server registry**: `servers: [SHServerConfig]` + `serverStore` + health
  (`verifiedServerID`, `isVerifiedServerReachable`, health/recheck tasky, `lmClient`).
- **Recents** (app-level): `recentFolders`, `recentFolderBookmarks`,
  `recentProjectURLs`, `projectBookmarks` + jejich persistence.
- **App prefs** (přesun z `SHAppConfig`, viz níže): `SHAppPreferences` — souběžnost,
  throttle, modelContextTokens, requestTimeoutSeconds, bypassInferenceCache,
  ocrBackend, ocrLanguages, ocrTimeoutSeconds, officeConversionEnabled,
  popplerPDFTextEnabled, spreadsheetConversionEnabled, lastRunAvg*Ms. Persistované
  do UserDefaults přes nový `SHPreferencesStore`.
- **Sdílené služby**: `promptService`, `exportService`, `benchmarkService`.

### `SHProjectDocument` (`ReferenceFileDocument`)
Single source of truth pro **obsah projektu**. Drží `SHProjectContent` (Codable):
`inputFolder/outputFolder/cacheFolder/promptFolder` cesty + `folderBookmarks`,
`selectedServerID`, `selectedInferenceModel/Embedding/Reranker/OCR`,
`extractionMode`, `currentPrompt`, `lastLoadedPromptName`, `promptHistory`.
- `UTType` se napojí na **existující** UTI z varianty B —
  `DavidMasin.SpiceHarvester.project` (přípona `spiceharvester.json`, conforms
  `public.json`, už deklarovaný v `Info.plist`). Definuje se `extension UTType { static let spiceHarvesterProject = UTType(exportedAs: "DavidMasin.SpiceHarvester.project") }`.
- `static var readableContentTypes = [.spiceHarvesterProject]`
- `static var writableContentTypes = [.spiceHarvesterProject]`
- `CFBundleDocumentTypes` záznam (z varianty B) zůstává role `Editor` — DocumentGroup
  ho použije pro New/Open/Recent.
- `snapshot(contentType:) -> SHProjectContent`
- `func fileWrapper(snapshot:configuration:)` → JSON (`SHJSON.encoder`)
- `init(configuration:)` → JSON decode (tolerantní, decodeIfPresent)
- DocumentGroup zajistí autosave / verze / modified-dot / Cmd+S.

### `SHDocumentViewModel` (`@MainActor @Observable final class`)
Přejmenovaný odlehčený `SHAppViewModel`. Per-okno. Drží:
- Referenci na `SHProjectDocument` (čte/zapisuje obsah → změny vidí autosave/undo).
- Referenci na `SHGlobalState` (servery, recents, prefs, služby).
- **Runtime stav** (per okno): `availableModels`, `availablePromptFiles`,
  `selectedPromptFile`, `benchmark`, `progressState`, `logText`, `statusText`,
  `isRunning`, `lastCompletion`, `loadedResult`, `inputFolderPdfCount/Bytes`,
  `inflightItems`, caches, logger, tasky, konflikty, setup steps.
- **Celou run logiku** (`runAll`, `runPreprocessing`, `runExtraction`, cache,
  embeddings, export) — chování beze změny; jen čte folders/modely z dokumentu
  a prefs/servery z global.

Vytvoří se v `ContentView` jako `@State` z `document` + `globalState` (environment).

### `SHAppConfig` split
Dnešní `SHAppConfig` se rozdělí:
- **`SHProjectContent`** — to, co patří do dokumentu (folders, bookmarky, modely,
  prompt, mode, promptHistory).
- **`SHAppPreferences`** — app-level prefs (viz `SHGlobalState`).

`folderBookmarks` zůstávají v dokumentu (jsou vázané na cesty projektu); recents
bookmarky jsou v global.

## Scéna (`SpiceHarvesterApp`)
- `WindowGroup(id:"main")` + scratch `WindowGroup` → nahradit **`DocumentGroup(newDocument: SHProjectDocument())`**.
- Content closure: `ContentView(document: file.$document, global: globalState, showHelp:)`.
- Help okno (`Window id:"help"`) zůstává.
- Settings scéna bind na `globalState` (app prefs), ne na document.
- Menu commands (Pipeline run/stop/mode, atd.) routují na **focused document's VM**
  přes `@FocusedValue` (analogicky dnešnímu `focusedViewModel`).
- `recentProjectMenuTitle` + vlastní „Otevřít nedávné" → **nahradit nativním**
  File→Open Recent (DocumentGroup ho dodá zdarma); custom recents kód odstranit.

## Migrace
`SHMigration` (čistá, testovatelná):
1. Při startu: pokud existuje legacy UserDefaults config (`SHConfigStore`) a ještě
   neproběhla migrace (flag v UserDefaults), zkonvertuj `SHAppConfig` →
   `SHProjectContent` + `SHAppPreferences`.
2. Prefs zapiš do `SHPreferencesStore`. Content zapiš do
   `~/Documents/Spice Harvester/Default Project.spiceharvester.json`.
3. Nastav migrační flag. Při dalším startu DocumentGroup nabídne tento soubor
   přes Open Recent / restorace oken.
- API klíče (Keychain) a server registry zůstávají v UserDefaults/Keychainu (global),
  migrace se jich netýká.

## AppIntents (B)
`RunSpiceHarvesterIntent` (+ `targetFolder`, `mode`, `promptName` parametry):
- Headless: načti/zkonstruuj `Default Project.spiceharvester.json` →
  `SHProjectContent`, vytvoř dočasný `SHDocumentViewModel` proti sdílenému
  `SHGlobalState`, aplikuj parametry, spusť, počkej na completion, vrať cestu k
  `results.csv` (zachová stávající `ReturnsValue<String>` sémantiku).
- `SHGlobalState` musí být dosažitelný i bez UI okna (app-level singleton držený
  v `SHAppDelegate`/App).

## Inventář call sites k přepojení
- `SpiceHarvesterApp.swift` — scéna, commands, focused routing, Settings bind.
- `ContentView.swift` — konstrukce VM z dokumentu, všechny `vm.config.*` přístupy
  (folders/modely/prompt z dokumentu; prefs z global).
- `SettingsView.swift` — bind na `globalState` prefs místo `vm.config`.
- `SHAppDelegate` — `application(_:open:)` (projekty teď řeší DocumentGroup; ponechat
  jen result-file `.spice-result.json` cestu), držení `SHGlobalState` pro intenty.
- `AppIntents/SHAppIntents.swift` — headless cesta přes Default Project.
- Odstranit interim: custom Save/Load Project commands, scratch WindowGroup,
  custom recents (nahrazeno nativním DocumentGroup lifecyclem).

## Testy
- `SHProjectContent` Codable roundtrip (vč. tolerantního decode chybějících polí).
- `SHAppPreferences` Codable roundtrip + defaulty.
- `SHMigration` čistá funkce: legacy `SHAppConfig` → (`SHProjectContent`, `SHAppPreferences`).
- Zachovat existující tooling/OCR/registry testy (po přejmenování VM).
- DocumentGroup scény se neunit-testují; ověření buildem + manuálně.

## Strategie exekuce (inkrementálně, zelený build po každé fázi)
1. **Split datových modelů** — `SHProjectContent` + `SHAppPreferences` + stores + migrace + testy. (app jede dál na starém VM, nové typy zatím nevyužité)
2. **`SHGlobalState`** — vyčlenit servery/recents/prefs/služby z VM; VM drží referenci. Build green.
3. **`SHDocumentViewModel`** — přejmenovat VM, config→dokument obsah, runtime ponechat.
4. **`SHProjectDocument` + `DocumentGroup` scéna** — přepnout scénu, ContentView konstrukce, focused routing.
5. **Settings + AppIntents** — Settings na global prefs; intent přes Default Project.
6. **Migrace zapojit + úklid interimu** — smazat custom Save/Load/scratch/recents; migrace při startu.

Každá fáze = samostatný commit s buildem (a testy, kde existují).

## Mimo rozsah
- iCloud Drive sync (vyřazeno dřív).
- Změna formátu výstupů (`results.*`, `*.spice-result.json`).
- Změna run/pipeline logiky (jen se přesune, nemění chování).

## Rizika
- **Dotkne se každého call site VM** — vysoká pravděpodobnost regresí; mitigováno
  fázovaným postupem se zeleným buildem.
- **AppIntents bez UI okna** — headless přístup ke global state musí fungovat i
  při launchi z Shortcuts.
- **Migrace** musí být idempotentní (flag) a nesmí ztratit existující konfiguraci.
- **Settings prefs přesun** mění `SHAppConfig` API → dotkne se run logiky čtoucí
  prefs (timeout, concurrency, OCR) — pečlivě přemapovat na `globalState.prefs`.
