# Kódová dokumentace

Aktuální dokumentace odpovídá aktivnímu runtime (SwiftUI + MVVM + dvoufázová pipeline). Legacy implementace je přesunuta do `Legacy/` a není součástí aktivního targetu.

## 1. Architektura

Aplikace je rozdělená do vrstev:

- `Views` – SwiftUI obrazovky
- `ViewModels` – stav UI, validace vstupů a orchestrace běhů
- `Services` – IO, HTTP, PDF, OCR, prompty, konfigurace, prompt analyzer
- `Pipeline` – dvoufázové dávkové zpracování + queue management
- `Cache` – JSON cache dokumentů + content-addressable inference cache
- `Logging` – průběžný log do `processing.log`
- `Export` – JSON/TXT/CSV/raw export + rozhraní pro XLSX
- `Models` – datové modely (`Codable`, `Sendable`)

## 2. Dvoufázová pipeline

### FÁZE 1: Předzpracování + cache
Hlavní typ: `SHPreprocessingPipeline`

Kroky:
1. Rekurzivní scan PDF (`SHFileScanService.recursivePDFs`)
2. SHA-256 hash souboru, **streamovaně po 1 MiB** (`SHFileScanService.sha256`)
3. Cache hit/miss (`SHCacheManager`)
4. Text layer přes PDFKit (`SHPDFParser.parse`) nebo OCR fallback (`SHVisionOCRProvider`)
5. Čištění textu po stránkách (`SHTextCleaningService`)
6. Uložení `SHCachedDocument` do JSON cache (při cache hit s přejmenovaným souborem se metadata updatují a uloží zpět)

`SHCachedDocument` obsahuje:
- `sourceFile`, `fileHash`, `processedAt`
- `rawText`, `cleanedText`
- `pages[]` (`SHDocumentPage`)
- `metadata` (`pageCount`, `usedOCR`, `hasTextLayer`)

### FÁZE 2: Extrakce přes lokální OpenAI-compatible server
Hlavní typ: `SHExtractionPipeline`

Kroky (dle režimu):
1. **Výběr kontextu** podle režimu (`FAST`/`SEARCH`/`CONSOLIDATE`)
2. **Inference cache lookup** — pokud hit, odpověď se vrací instantně (v CONSOLIDATE před pre-flight)
3. V CONSOLIDATE: **pre-flight token budget check** (ceil(chars / 3) vs. `consolidateInputBudget × modelContextTokens`). Fail-fast s actionable zprávou dřív, než se pošle request do lokálního AI serveru.
4. `Task.checkCancellation()` před LLM voláním (propagace cancel během čekání ve frontě)
5. Volání `/chat/completions` (přes `SHOpenAICompatibleClient` s retry na transient chyby)
6. **Best-effort decode** proti kanonickému `SHExtractionResult` (bez repair flow). Při neúspěchu se raw odpověď uloží do `rawResponse`.
7. Cache save (jen když `!json.isEmpty` — aby prázdné / broken odpovědi nezamořily cache)
8. Merge partial výsledků (pouze FAST/SEARCH s více prompty per dokument)

Repair flow (volání LLM podruhé s kanonickým schématem) byl **odstraněn** — pro uživatelské custom prompty produkoval falešné kanonické záznamy a plýtval inferencí.

## 3. Režimy extrakce

`SHExtractionMode`:
- `fast` – per-document inference, bez embeddings, kontext = celý `cleanedText`
- `search` – per-document inference + chunking + embeddings (RAG), paralelní embedding calls přes `TaskGroup`
- `consolidate` – všechny dokumenty v jednom requestu, jedna agregovaná odpověď; při přetečení kontextu **auto-fallback na map-reduce**

Fallback v SEARCH: při chybě embedding endpointu/modelu se použije prvních N chunků bez skóre. Pokud je nastavený reranker model, SEARCH po embedding rankingu vezme širší kandidátní sadu (`searchRerankCandidates = 20`) a pošle ji na `/v1/rerank`; při chybě rerankeru pokračuje původním embedding rankingem. Pole `searchChunkSize = 1500`, `searchChunkOverlap = 250`, `searchTopChunks = 6` (konstanty v `SHExtractionPipeline`).

### Map-reduce v CONSOLIDATE

Když preflight odhad tokenů (`ceil(chars / czechCharsPerToken)`) přesáhne `consolidateInputBudget × modelContextTokens`, pipeline **nevyhodí chybu**, ale přejde na `runMapReduce`:

1. **Packing**: greedy algoritmus naplní dávky dokumentů tak, aby se každá vešla do per-batch budgetu (s overhead pro wrapper prompt). Jeden oversized dokument dostane vlastní dávku (LM volání pak pravděpodobně selže, ale user vidí, který soubor je problém).
2. **MAP fáze**: pro každou dávku N/M se volá LLM s wrapper promptem *"Toto je dávka #N z M. Zpracuj jen přiložené dokumenty, vrať výstup ve stejném formátu"* + originální user prompt + dokumenty dávky. Každá dávka má vlastní cache slot (`modeTag: consolidate-map`) — částečný progress přežije cancel/restart.
3. **REDUCE fáze**: všechny MAP výstupy se pošlou v jednom posledním volání s promptem *"Spoj dílčí výstupy do jediného, deduplikuj záznamy, zachovej formát"*. Má vlastní cache slot (`modeTag: consolidate-reduce`) s klíčem zahrnujícím `batches=\(batchCount)` pro invalidaci při změně velikosti dávek.
4. **Fallback**: pokud reduce selže, pipeline vrátí surové dávky spojené markery `=== Dávka #N ===` v `rawResponse` + warning — uživatel má aspoň per-dávku data.
5. **Progress reporting**: `onProgress(0, K+1)` → `onProgress(K, K+1)` (po MAP) → `onProgress(K+1, K+1)` (po REDUCE).

Celý map-reduce běh zachovává `Task.checkCancellation()` mezi fázemi — cancel přeruší ještě nedokončené dávky.

### Auto-refresh kontextu před CONSOLIDATE

Před spuštěním CONSOLIDATE runu VM volá `refreshModelContextIfRisky(server:)`:
- Odhadne vstupní velikost z `cachedDocuments`.
- Pokud překračuje 50 % aktuálního `config.modelContextTokens`, tiše se dotáže LM Studia (`/api/v0/models`) na aktuální `loaded_context_length`.
- Při rozdílu aktualizuje `config.modelContextTokens` + persistuje + informuje uživatele ve statusbaru.

Pokrývá případ, kdy uživatel mezi `Ověřit server` a `Spustit` v LM Studiu restartoval model s jinou context velikostí.

## 4. Inference cache

### `SHInferenceCache`
Content-addressable actor cache pro LLM odpovědi.

Klíč `makeKey(...)` je SHA-256 nad:
- `schemaVersion` (konstanta — invaliduje po upgrade appky)
- `systemPrompt` (interní fixní prompt)
- `prompt` (uživatelův obsah)
- `cleanerVersion` (`SHTextCleaningService.version` — bump při změně cleaneru invaliduje cache)
- seřazené `documentHashes`
- `model` (inference model ID)
- `embeddingModel` (v SEARCH, jinak prázdné)
- `rerankerModel` (v SEARCH s rerankingem, jinak prázdné)
- `modeTag` (fast/search/consolidate)

Hodnota: JSON envelope `{createdAt, model, modeTag, response}`.

Umístění: `{cacheRoot}/inference/{hash}.json`.

Změna kterékoli komponenty klíče → miss → nová inference. Identické vstupy → instant hit.

Toggle `bypassInferenceCache` v `SHAppConfig` přeskočí čtení cache (pro non-deterministické modely nebo záměrné re-run).

## 5. Queue a concurrency

### `SHQueueManager`
- FIFO async semaphore nad `maxConcurrent` pracovníky
- `SHAsyncSemaphore`: waiters v `[Waiter]` array (deterministické FIFO), cancellation-safe (handler odstraní waiter z array a resumuje s `CancellationError`)
- `run(...)` má `defer { Task { await semaphore.signal() } }` — garantuje uvolnění slotu na každé exit cestě

Samostatné queues:
- PDF/OCR předzpracování
- Inference požadavky

Konfigurovatelné (`SHAppConfig`):
- `maxConcurrentInference`
- `maxConcurrentPDFWorkers`
- `throttleDelayMs` (pozor — pro CONSOLIDATE nemá efekt, v FAST/SEARCH běží post-inference)

## 6. Konfigurace a persistence

### `SHAppConfig`
Persistované přes `SHConfigStore` (`UserDefaults`):
- vstup/výstup/cache/prompt složka
- **security-scoped bookmarks** (`folderBookmarks: [String: Data]`) pro sandbox přístup
- vybraný server (`selectedServerID`)
- vybraný inference / embedding model
- `extractionMode`
- concurrency limity a throttle (`maxConcurrentInference`, `maxConcurrentPDFWorkers`, `throttleDelayMs`)
- `modelContextTokens` (auto-detect z LM Studia nebo ruční stepper)
- `bypassInferenceCache`
- `currentPrompt`, `lastLoadedPromptName`
- **baseline pro odhad výkonu**: `lastRunAvgDocumentMs`, `lastRunAvgPageMs` (zapisuje se po úspěšném runu)

Poznámka k runtime: **při startu se část hodnot záměrně resetuje** (složky, bookmarky, text promptu, model selections), aby session začínala čistě. Persistují hlavně servery, výkonové preference, kontext modelu a průměry z posledního runu.

**Flush při ukončení**: `NSApplication.willTerminateNotification` → `persistAll()` (vynutí zapsání jakékoli pending debounced změny).

### Registry serverů
`SHServerRegistryStore` ukládá pole `SHServerConfig`:
- `id` (UUID)
- `name`, `baseURL`, `apiKey`

Chyby dekódu se logují do `os.Logger`, ne polykají přes `try?`.

Model selection (`selectedInferenceModel`, `selectedEmbeddingModel`, `selectedRerankerModel`, `selectedOCRModel`) není vlastnost serveru, ale globální runtime config. Po přepnutí serveru, přidání serveru, odebrání serveru nebo změně Base URL/API key volá VM reset model state: vyčistí `availableModels` a všechny model selections. Při `verifyServer()` se z `/v1/models` načte aktuální seznam; pokud `selectedInferenceModel` není v seznamu, nastaví se první dostupný model, a pokud embedding/reranker/OCR model není v seznamu, vyprázdní se. Tím se brání přenosu model ID mezi backendy (např. LM Studio → MLX).

## 7. OpenAI-compatible klient

`SHOpenAICompatibleClient` používá obecné OpenAI-compatible endpointy. Funguje proto s LM Studiem i MLX backendy, které vystavují kompatibilní API:
- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/embeddings`

**Retry na transient chyby** (`send(_:)` wrapper):
- HTTP 502/503/504
- `URLError.timedOut`, `.networkConnectionLost`, `.cannotConnectToHost`, `.dnsLookupFailed`
- Exponenciální backoff: 1 s → 3 s → 9 s (cap 10 s), `maxAttempts = 3`
- `CancellationError` propaguje bez retry

**LM Studio native API** (`fetchLoadedModels`):
- `GET /api/v0/models` — vrací rozšířená metadata vč. `max_context_length` a `loaded_context_length`
- Volá se z `verifyServer()` jako best-effort. U MLX a jiných ne-LM-Studio serverů tichý fail → context stepper zůstává na manuální hodnotě a status bar ukáže `kontext ručně`.
- Helper `lmStudioNativeEndpoint` umí strip trailing `/v1`.

**Embedding capability check**:
- Po výběru embedding modelu VM spustí lehký testovací `/v1/embeddings` request přes `supportsEmbeddings(server:model:)`.
- Úspěch nastaví status `Embedding endpoint ověřen`.
- Selhání nastaví status `Embedding endpoint nedostupný – SEARCH použije fallback bez RAG`; runtime fallback v `SHExtractionPipeline` zůstává zachovaný.

**Rerank**:
- `SHOpenAICompatibleClient.rerank(...)` volá `POST /v1/rerank` ve stylu `{model, query, documents, top_n}`.
- `SHExtractionPipeline.contextForPrompt` používá reranker jen v SEARCH a jen když je vybraný model. Reranker selhání je non-fatal.

**OCR backendy**:
- `SHVisionOCRProvider` zůstává default.
- `SHOpenAIVisionOCRProvider` renderuje stránky přes `SHPDFParser.renderPageImage`, posílá je jako data URL image do `/v1/chat/completions` a vrací přepsaný text.
- `SHFallbackOCRProvider` používá Vision výsledek po stránkách. Pokud je konkrétní stránka prázdná nebo má méně než `minimumUsableCharacters`, doplní její text z VLM fallbacku; tím se u smíšených PDF neztratí skenované stránky, kde Vision selhal.
- Cache hash předzpracování zahrnuje OCR backend/model signature, aby změna OCR strategie nepoužila starý text z diskové cache.

Autorizace: `Bearer` header pokud `apiKey` je vyplněn.

Strukturované chyby: `SHLMError { badURL, http, emptyResponse, emptyEmbedding }`.

## 8. Prompt Analyzer

`SHPromptAnalyzer` — keyword-based heuristika pro detekci nesouladu mezi promptem a nastavením.

`suggestedMode(for:)` projde v pořadí:
1. CONSOLIDATE keywords ("celý vstup jako jeden", "napříč dokumenty", "jediný JSON array", "aggregate", "consolidate", …) — ~27 klíčů
2. FAST keywords ("pro každý dokument", "per file", …) — ~7 klíčů
3. SEARCH keywords ("semantic", "retrieval", "rag", …) — ~6 klíčů

První match vítězí + vrací `ModeSuggestion { mode, reason }`.

Typy konfliktů (`SHParameterConflict`):
- `.modeMismatch(current, suggested, reason)` — prompt žádá jiný režim; banner s jedno-klikovým přepnutím
- `.searchModeWithoutEmbeddingModel` — SEARCH bez embedding modelu; banner s přepnutím na FAST
- `.consolidateIgnoresConcurrency` — informační; CONSOLIDATE ignoruje workery a throttle

V `SHAppViewModel.parameterConflicts` se recomputují přes `@Observable` tracking při změně promptu nebo configu.

## 9. Text cleaning

`SHTextCleaningService` filtruje boilerplate z PDF extraktů:

- **Opakované hlavičky/patičky** napříč stránkami (frequency threshold `max(2, 0.45 × pages)`)
- **Čísla stránek**: anchored regex `^strana|^stránka|^str\.|^page|^\d+/\d+|^- N -|^\d+$`
- **Signature lines** (anchored `hasPrefix`): `mudr.`, `prim.`, `doc.`, `prof.`, `podpis:`, `razítko:`, `vypracoval*`, `provedl*`, `zapsal*`, `ověřil*`, `podepsán`, `vedoucí lékař`, …
- **Credential-only krátké řádky** (< 80 znaků) s `ph.d.`, `csc.`, `dr.sc.`
- **Visual noise** (anchored `hasPrefix`): `logo `, `www.`, `http`, `fakultní nemocnice`, `nemocnice `
- **Krátké department labels** (< 32 znaků, hasPrefix): `oddělení`, `klinika`, `ambulance`
- **Contact / address** (anchored): `tel:`, `fax:`, `e-mail:`, email-only řádek regex, `ičo:`, `ičz:`, `ičp:`, `dič:`, PSČ regex anchored na začátek řádku
- **Audit trail**: `vytištěno dne`, `č.j.`, `spisová značka`, `formulář č.`, `copyright`, …
- **OCR glyph noise**: < 25 % písmen/číslic = dekorace
- **Horizontal rules**: `====`, `----`, `____`, `*`, box-drawing znaky

Důsledný design: **žádné stripování medicínského obsahu**. Patterny jsou anchored na `hasPrefix`, takže věty typu *"kontrolu u praktického lékaře"* nebo *"přijat na oddělení kardiologie"* zůstávají.

`static let version = "v2"` — bump při změně logiky pro invalidaci inference cache.

## 10. Logging

`SHProcessingLogger` je actor zapisující do `processing.log`:

```text
timestamp | level | file | phase | message | duration_ms
```

Timestampy v **lokálním časovém pásmu** (ISO-8601 s offsetem).

Implementace:
- Cached `FileHandle` (neotevírá/nezavírá na každý call)
- `readTail(maxLines:)` čte jen posledních 256 KB okna, ne celý soubor
- Escape `|` → `¦` a newlines → space v polích (parseovatelný formát)

Phase hodnoty:
- `HASH`, `CACHE`, `TEXT`, `OCR`, `INFERENCE`, `INFERENCE-CACHE`, `EMBEDDING`, `VALIDATE`, `PREFLIGHT`, `PREPROCESS`

## 11. Benchmark

`SHBenchmarkService` sbírá metriky:
- `scanMs`, `ocrMs`, `textExtractionMs`, `inferenceMs`
- `totalPages` (volá se `recordPages(_:)` jednou per dokument — dřív se dvojnásobně počítalo při OCR fallbacku)
- `totalDocuments`
- `wallClockMs` (od prvního zaznamenaného phase)

Computed:
- `avgPerPageMs`
- `avgPerDocumentMs`
- `throughputDocsPerMinute` (preferuje `wallClockMs` jako jmenovatel — fallback na sumu phase).

Po úspěšném runu se `avgPerDocumentMs` a `avgPerPageMs` persistují do `config.lastRunAvg*Ms` jako baseline pro **odhad dalšího runu** v UI kartě **Výkon**.

## 12. Export

`SHExportService` exportuje do výstupní složky:

**Kanonický tvar** (`SHExtractionResult` schema):
- `results.json` — pole všech výsledků
- per-file `*.json` (s deduplikací názvů přes `{name}_2`, `{name}_3`, …)
- `results.txt` — human readable + sekce `--- Raw odpověď modelu ---`
- `results.csv` — 1 řádek na dokument, UTF-8 **BOM** pro Excel na macOS, LF line endings (CRLF rozbíjelo Swift `split(separator: "\n")` kvůli grapheme clusterům)

**Raw výstupy** (`exportRawResponses`):
- Detekce `=====CSV=====` / `=====TXT=====` markerů → zvlášť `{name}_raw.csv` (BOM) + `{name}_raw.txt`
- Jinak validní JSON → pretty-printed `{name}_raw.json`
- Jinak plain text → `{name}_raw.txt`
- Agregát: `raw_responses.json` mapa `{fileName: parsedOrRaw}` pro batch consumery

Sdílený `SHJSON.encoder()` / `.decoder()` factory pro konzistenci.

XLSX rozhraní `SHXLSXExporting` (`SHXLSXExportPlaceholder`) — nerealizováno; CSV s BOM pokrývá Excel use case.

## 13. UI a ViewModel

### `SpiceHarvesterApp` (App scene)
Hostuje `@State vm = SHAppViewModel()` na úrovni App, takže ho sdílí hlavní okno i `Settings` scéna. Definuje:
- `WindowGroup { ContentView(vm:, showHelp:) }` — `defaultSize 1180×980`, fyzická velikost se po startu adaptuje přes `SHAppDelegate` na `NSScreen.visibleFrame`.
- `.commands { CommandGroup(replacing: .newItem) { … }; CommandGroup(replacing: .help) { … } }` — registruje shortcuty Cmd+R / Cmd+. / Cmd+Shift+P / Cmd+Shift+E / Cmd+Shift+O / Cmd+?, navázané přímo na `vm` (`canRunAll`, `canRunPreprocessing`, …).
- `Settings { SettingsView(vm:) }` — nativní macOS Settings okno otevíratelné Cmd+, přes Spice Harvester → Settings… z menu.

### `ContentView` (dvousloupcový layout)
- **Window toolbar** (`.toolbar { ToolbarItem(.navigation) { statusIndicator }; ToolbarItemGroup(.primaryAction) { runOrStop / Output / Help } }`) — single source of truth pro Run/Stop. Stav (zelená tečka „Připraveno" / spinner „Zpracovávám…") sedí vlevo, akce vpravo. `Přerušit` má `role: .destructive`.
- **Hlavní layout** = `HSplitView`:
  - **Levý sloupec (konfigurace)** ve vlastním `ScrollView`:
    - `header` (logo + název + subtitle, **bez** progress pillu i help buttonu — obojí je v toolbaru)
    - `foldersCard` — 4× read-only folder row s `Text` v rounded boxu, **drag-and-drop** přes `.dropDestination(for: URL.self)` (akceptuje pouze adresáře), tlačítko „Vybrat" / „Změnit" otevírá `NSOpenPanel`
    - `serverCard` — picker + add/remove + MLX preset + Ověřit + 4 model pickery v `Grid(2×2)` (Inference / Embedding / Reranker / OCR-VLM) + segmented `Režim extrakce` + caption s popisem aktivního režimu (`modeHintText`)
    - `promptsCard` — Načíst + picker `.md` + nothink/think tlačítka + Vymazat + `TextEditor` + parameter conflict bannery
  - **Pravý sloupec (runtime)** **bez** outer `ScrollView`:
    - `completionBanner` (jen pokud `vm.lastCompletion != nil`, „Hotovo / Přerušeno / Selhalo" + Potvrdit)
    - `progressStatusCard` (tři stavy idle / předzpracování-extrakce / finished, `TimelineView(.periodic)` pro live ETA + health row)
    - `logCard` (`frame(maxHeight: .infinity)`, ScrollViewReader auto-scroll, `Obnovit` button — `vm.logText` se z disku obnovuje až mezi fázemi)
- **Status bar** (dolní lišta plné šířky) — `vm.statusText` v `.caption`, kruhový indikátor 10 pt.

**Co se z hlavního okna přesunulo do Settings (Cmd+,):** OCR backend, výkonové steppery (souběžnost, throttle, kontext modelu), timeout požadavku, `bypassInferenceCache` toggle, `Vyčistit cache` (s `role: .destructive`).

Monochromatický design: primary color pro dekoraci, **zelená** rezervovaná jen pro „verified / selected / done" stavy. Modrá pro aktivní akční tlačítka, disabled (šedá) pro nesplněné prerekvizity. `GlassCard` má `.regularMaterial` + 0.5 pt stroke; **drop shadow byl odstraněn** (5+ stínovaných karet na window-sized gradientu šuměly bez přidaných informací).

### `SettingsView` (nativní macOS Settings scene)
Settings je nativní `Settings { SettingsView(vm:) }` scéna, ale obsah nepoužívá systémový `TabView` tab strip. Kvůli chybě macOS renderování vybraného tab itemu ve světlém režimu má vlastní horní přepínač (`SettingsTab`) s explicitním `.primary` / `.secondary` textem. Okno má pevný frame **620×540 pt**, aby se vešel celý obsah bez useknutí spodních sekcí.

Struktura:
- Horní titul `Text(selectedTab.title)` + tři ikonové buttony (`speedometer`, `doc.text.viewfinder`, `externaldrive`), vybraný tab má jemný primary background + stroke.
- `selectedTabContent` switchuje mezi třemi `Form` views (`.formStyle(.grouped)`).
- **Výkon** — sekce **Souběžnost** (`maxConcurrentInference` 1–16, `maxConcurrentPDFWorkers` 1–16, `throttleDelayMs` 0–2000 ms po 50 ms) a **Model a HTTP** (`modelContextTokens` 4096–1048576 po 4096, `requestTimeoutSeconds` 60–3600 po 60 s). Změna timeoutu volá `vm.rebuildLMClient()`, protože `URLSessionConfiguration.timeoutIntervalForRequest` se po vytvoření session nedá měnit.
- **OCR** — `Picker(.inline)` na `SHOCRBackend` s vysvětlujícím footerem: Apple Vision lokálně, oMLX/VLM přes OpenAI-compatible vision požadavky, Vision→VLM jako fallback.
- **Cache** — toggle `bypassInferenceCache` + `Vyčistit cache` (`role: .destructive`), které maže per-dokument i per-inference cache.

Sdílí `vm` s hlavním oknem přes `@Bindable`; změny v Settings persistují přes `vm.persistAll()` / specializované setter metody.

### `HelpSheet`
Modální sheet otevíratelný z toolbar tlačítka i z Cmd+?. Vlastní strukturované sekce (Co aplikace dělá, Co si připravit, Postup, Režimy, Tipy) s reusable helpery `section / paragraph / step / bullet / mode`. Bez vlastního state — dismiss callback dodává parent.

### `GlassCard`
Sdílený materiálový kontejner. `.regularMaterial` + `RoundedRectangle(cornerRadius: 10, .continuous)` + 0.5 pt stroke `Color.primary.opacity(0.06)`. Header `HStack` s ikonou (`.caption`, `.secondary`, `.symbolRenderingMode(.hierarchical)`) + titulkem (`.subheadline.weight(.semibold)`, `.secondary`). Padding 12, VStack spacing 8.

### `SHAppViewModel`
Centrální orchestrátor (`@MainActor @Observable`).

Hlavní operace:
- `verifyServer()` — ping + `/v1/models` + `/api/v0/models` (LM Studio context auto-detect)
- `reloadPromptFiles()`, `loadPromptFile(_:)`, `clearPrompt()`
- `runPreprocessing()`, `runExtraction()`, `runAll()` — každá přes `executeRun { ... }` single-entry guard
- `cancelRun()` — propaguje `CancellationError` do pipeline
- `acknowledgeCompletion()` — skryje completion badge
- `clearCache()` — nuke per-dokument i per-inference cache
- `refreshLog()`, `openOutput()`

`runXxx` metody interně volají `performXxx()` které vrací **typed `SHRunOutcome`** enum (`.success / .cancelled / .failed / .notStarted`). `executeRun` klasifikuje outcome z return value (dřív z `statusText.lowercased()` — fragile heuristika, teď odstraněna).

`.notStarted` (preconditions failed) **nezobrazí** completion badge — UI zůstává v ready stavu.

Parameter conflicts (`parameterConflicts: [SHParameterConflict]`) se recomputují na změnu promptu / configu.

Výkonové odhady:
- `pendingDocumentCount`
- `estimatedPerDocumentMs`
- `estimatedRunDurationMs`

Důležité chování:
- `runExtraction()` automaticky spustí předzpracování, pokud ještě nejsou data v paměti
- Změna input folderu (přes picker i onChange) invaliduje `cachedDocuments`
- `lastPickedFolderParent` session-only state — další folder picker otevře rodiče minulého výběru (sourozenecké složky na 1 klik)
- `persistAllDebounced()` (300ms) pro keystroke-driven bindings (URL, API key, prompt text), flush na `willTerminateNotification`

## 14. Aktivní struktura projektu

```text
SpiceHarvester/
  Models/
    SHAppConfig.swift
    SHDocumentModels.swift
    SHExtractionResult.swift
    SHProgressViewState.swift
  ViewModels/
    SHAppViewModel.swift
  Views/
    GlassCard.swift       — sdílený materiálový kontejner
    HelpSheet.swift       — nápověda (Cmd+?)
    SettingsView.swift    — Settings scéna (Cmd+,) s taby Výkon/OCR/Cache
  Services/
    SHBenchmarkService.swift
    SHConfigStore.swift
    SHFileScanService.swift
    SHOpenAICompatibleClient.swift
    SHOCRProvider.swift
    SHPDFParser.swift
    SHPromptAnalyzer.swift
    SHPromptLibraryService.swift
    SHResultSchemaValidator.swift
    SHServerRegistryStore.swift
    SHTextCleaningService.swift
  Pipeline/
    SHExtractionPipeline.swift
    SHPreprocessingPipeline.swift
    SHQueueManager.swift
  Cache/
    SHCacheManager.swift
    SHInferenceCache.swift
  Logging/
    SHProcessingLogger.swift
  Export/
    SHExportService.swift
  ContentView.swift
  SpiceHarvesterApp.swift
```

Legacy soubory (archivováno):
```text
Legacy/
```

## 15. Build a signing

Target používá oddělené entitlement soubory podle konfigurace:

- `SpiceHarvester/SpiceHarvesterDebug.entitlements` — Debug konfigurace. Obsahuje sandbox + user-selected folders + network oprávnění a vývojové `com.apple.security.cs.*` výjimky (`debugger`, `allow-dyld-environment-variables`, `allow-unsigned-executable-memory`, `disable-executable-page-protection`, `disable-library-validation`).
- `SpiceHarvester/SpiceHarvester.entitlements` — Release konfigurace. Obsahuje jen produkční sandbox oprávnění: `app-sandbox`, `files.user-selected.read-write`, `network.client`, `network.server`.

Konfigurace je nastavená v `SpiceHarvester.xcodeproj/project.pbxproj` přes `CODE_SIGN_ENTITLEMENTS` zvlášť pro Debug a Release. Release build se ověřuje:

```bash
xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Release -destination 'platform=macOS'
```

## 16. Testy

Aktivní testy (`SpiceHarvesterTests`):
- `extractionResultMergeFillsOnlyMissingFields` — merge logika
- `schemaValidatorAcceptsValidJSON` / `schemaValidatorRejectsMissingField` — strict schema validation
- `cacheManagerSaveLoadAndClear` — per-dokument cache
- `csvExportCreatesOneRowPerDocument` — CSV export (1 řádek/dokument + BOM + LF)
- `textCleanerRemovesRepeatedHeaderFooterCaseInsensitive` — dedup hlavičky/patičky

Aktivní UI testy (`SpiceHarvesterUITests`):
- `testSettingsTabsExposeExpectedContent` — běží přes `runsForEachTargetApplicationUIConfiguration`, takže se spouští ve světlém i tmavém režimu. Otevírá Settings přes `Cmd+,`, ověřuje taby `Výkon`, `OCR`, `Cache` a základní obsah každého tabu.

Spuštění:
```bash
xcodebuild test -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -destination 'platform=macOS'
```
