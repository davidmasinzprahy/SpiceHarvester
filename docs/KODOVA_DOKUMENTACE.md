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
- `Export` – JSON/TXT/CSV/raw export + import `.spice-result.json` + rozhraní pro XLSX
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

**Recent-folder bookmarky přežívají reset**: `config.folderBookmarks` se při startu maže, ale cesty v `recentFolders` se obnovují z UserDefaults. Aby výběr nedávné složky měl v sandboxu scoped přístup (jinak sken vrátí 0 PDF), drží se security-scoped bookmarky pro nedávné cesty v samostatném trvalém úložišti `recentFolderBookmarks: [String: Data]` (UserDefaults klíč `SHRecentFolderBookmarks`), analogicky k `projectBookmarks`. `resolveScopedURL` na toto úložiště padá jako **fallback** — záměrně se neseeduje zpět do `config.folderBookmarks`, aby se nezašpinil právě vyčištěný config slot. Při startu se store načte a profiltruje na cesty stále přítomné v `recentFolders` (bounded). Viz `resolveScopedURL`, `storeBookmark`, `staleSandboxPaths`.

**Sandbox přístup ke složkám**: každá cesta musí mít platný security-scoped bookmark, jinak ji sandbox nepřečte (sken vrátí prázdno). Bookmark vzniká při `NSOpenPanel` výběru (`pickFolder` → `storeBookmark`) i při **přetažení z Finderu** (`acceptDroppedFolder(_:kind:)` — z transientního grantu na dropnutém `URL` vytvoří bookmark; pouhé uložení cesty jako string by přístup ztratilo). `storeBookmark` zrcadlí bookmark i do `recentFolderBookmarks`.

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
- Exponenciální backoff `min(10, pow(3, attempt-1))`: 1 s → 3 s (cap 10 s). Při `maxAttempts = 3` proběhnou jen 2 retry (delay 9 s by nastal až u 4. pokusu, který se nekoná).
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
- `HASH`, `CACHE`, `TEXT`, `OCR`, `INFERENCE`, `INFERENCE-CACHE`, `EMBEDDING`, `PREFLIGHT`, `PREPROCESS`, `PLAN` (consolidate packing), `REDUCE` (map-reduce reduce), `RERANK` (SEARCH reranking)

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
- per-file `*.spice-result.json` (s deduplikací názvů přes `{name}_2.spice-result.json`, `{name}_3.spice-result.json`, …) — rozlišuje se podle UTI `DavidMasin.SpiceHarvester.result` deklarované v `Info.plist` (QuickLook náhled, Finder file association)
- `results.txt` — human readable + sekce `--- Raw odpověď modelu ---`
- `results.csv` — 1 řádek na dokument, UTF-8 **BOM** pro Excel na macOS, LF line endings (CRLF rozbíjelo Swift `split(separator: "\n")` kvůli grapheme clusterům)

**Raw výstupy** (`exportRawResponses`):
- Detekce `=====CSV=====` / `=====TXT=====` markerů → zvlášť `{name}_raw.csv` (BOM) + `{name}_raw.txt`
- Jinak validní JSON → pretty-printed `{name}_raw.json`
- Jinak plain text → `{name}_raw.txt`
- Agregát: `raw_responses.json` mapa `{fileName: parsedOrRaw}` pro batch consumery

Sdílený `SHJSON.encoder()` / `.decoder()` factory pro konzistencí výstupu i vstupu.

**Import `.spice-result.json`** (načtení exportovaných výsledků zpět do aplikace):
- Menu "Otevřít výsledek…" (Cmd+Shift+R) — `NSOpenPanel` filtrující `.json` soubory (zpráva odkazující na `.spice-result.json`)
- `SHAppViewModel.openSpiceResultFile(url:)` — načte soubor (`Data(contentsOf:)`), dekóduje přes `SHJSON.decoder().decode(SHExtractionResult.self, from:)`, nastaví `loadedResult` a `statusText` ("Načteno: <jméno> (<soubor>)")
- `application(_:open:)` na `SHAppDelegate` — handler pro Finder double-click / drag-on-icon při spuštění appky (bridging přes `weak primaryViewModel`)
- UI: pipeline tlačítka jsou disabled (`loadedResult != nil`), v notificationStack se zobrazí banner s patient info a "Zavřít" tlačítkem, které `loadedResult` resetuje na `nil`

XLSX rozhraní `SHXLSXExporting` (`SHXLSXExportPlaceholder`) — nerealizováno; CSV s BOM pokrývá Excel use case.

## 13. UI a ViewModel

### `SpiceHarvesterApp` (App scene) — multi-scene struktura

Aplikace registruje **4 Scene**:
- `WindowGroup(id: "main")` — primary okno s `vm = SHAppViewModel()` (`.persistent` mode, default). `.focusedSceneValue(\.focusedViewModel, vm)` propaguje view-model pro Cmd+? routing.
- `Settings { SettingsView(vm:) }` — nativní Cmd+, sheet, sdílí primary's `vm` (Settings je vždy globální per-app).
- `WindowGroup(id: "scratch", for: UUID.self) { _ in SHScratchRoot() }` — scratch okna otevíraná `openWindow(id: "scratch", value: UUID())` z menu Cmd+Shift+N. Každé má vlastní view-model (`.scratch` mode), vlastní `.focusedSceneValue(\.focusedViewModel, vm)`.
- `Window("Nápověda Spice Harvester", id: "help")` — samostatné okno nápovědy (singleton), otevírané `openWindow(id: "help")`.
- `defaultSize(width: 1180, height: 980)` na obou WindowGroup.

`SHAppDelegate` (`NSApplicationDelegateAdaptor`):
- `applicationDidFinishLaunching`: nastaví `UNUserNotificationCenter.delegate = self`, registruje completion notification category s "Otevřít výstup" akcí, volá `requestAuthorization`. Frame autosave přes `setFrameAutosaveName("SpiceHarvesterMainWindow")` — manuální resize/move se persistuje, první launch padne na `resizeMainWindowForCurrentScreen()` (visibleFrame logika).
- `UNUserNotificationCenterDelegate`: `willPresent` vrací `[.banner, .sound]` (banner i pro foreground), `didReceive` mapuje `OPEN_OUTPUT` action na `SHIntentNotifications.openOutput` post.
- `handleOpenProjectOutcome(_:)` static helper renderuje alert pro `successNeedsRepick` / `failed` cases.
- `primaryViewModel: weak SHAppViewModel?` — bridge property nastavená z `ContentView` `.onAppear` na `WindowGroup`, umožňuje `application(_:open:)` přístup view modelu i když delegate je vytvořen dříve než SwiftUI scéna.
- `application(_:open:)` — handler pro Finder double-click / drag-on `.spice-result.json` soubory. Pokusí se `primaryViewModel.openSpiceResultFile(url)`. Pokud je `primaryViewModel` nil (app ještě nenaběhla), zobrazí `NSAlert` místo silent drop.

`.commands` registruje:
1. `CommandGroup(replacing: .newItem)` — Nové okno (Cmd+Shift+N) / Otevřít projekt… (Cmd+O) / "Otevřít nedávné" submenu
2. `CommandGroup(after: .saveItem)` — Uložit projekt jako… (Cmd+Shift+S) / Otevřít výsledek… (Cmd+Shift+R) / Otevřít výstup ve Finderu (Cmd+Shift+O)
3. `CommandMenu("Pipeline")` — Spustit (Cmd+R) / Přerušit (Cmd+.) / Předzpracování (Cmd+Shift+P) / Extrakce (Cmd+Shift+E) / Režim FAST / SEARCH / CONSOLIDATE (Cmd+1 / Cmd+2 / Cmd+3) / "Znovu ověřit zdraví serveru"
4. `CommandGroup(replacing: .help)` — Nápověda (Cmd+?), volá `openWindow(id: "help")`

Plus `installTabKeyMonitor()` v ContentView's `.onAppear` registruje `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`:
- **Tab/Shift+Tab** (keyCode 48 bez Cmd/Ctrl/Option) → `advanceFocus(reverse:)` přes `enabledFocusOrder` (filter podle `canX` predikátů)
- **Cmd+F** (keyCode 3) → `focus = .logFilter`
- **Esc** (keyCode 53) → uvolní text input + `focus = .run`

### `ContentView` — dvousloupcový layout

**Levý sloupec (configuration + ovládání)**, min 460 pt / ideal 540 pt:
1. `header` — logo + název + subtitle
2. `leftConfigurationCards`:
   - `onboardingCard` (jen pokud !`vm.isSetupComplete`) — klikatelné chips
   - `foldersCard` — 4× folder row s `kind: SHFolderKind` parametrem; po prvním picknutí se Vybrat promění na Menu s "Naposledy" submenu (5 entries per kind). PDF chip pod Vstup.
   - `serverCard` — registry picker + add/remove + MLX preset + Ověřit + 3 textfieldy (name, URL s ⚠️ inline validací, API key)
   - `modelsCard` — Inference + OCR/VLM (vždy), Embedding + Reranker (jen v SEARCH), segmented Mode picker, mode hint caption
   - `Spacer(minLength: 0)` push
3. `Divider().opacity(0.4)`
4. `runRow` — Status pill + Spustit/Přerušit + Výstup + Nápověda (přes `ViewThatFits` adaptive labels)

**Pravý sloupec (workspace + monitoring)**, min 480 pt:
1. `notificationStack` — completion banner + conflict banners (oba `.accessibilityElement(children: .combine)`)
2. **VSplitView** (nebo plný `promptsCard` při `promptFullscreen`):
   - `promptsCard` (minHeight 170, ideal 290) + `dragHandleGrip` na bottom edge
   - `progressStatusCard` (minHeight 80, ideal 120) + `dragHandleGrip` na bottom edge
   - `logCard` (minHeight 150, ideal 250)

`logCard` používá `SHLogTextView` (NSViewRepresentable wrapping NSTextView) s severity coloring (`[ERROR]` red, `[WARNING]` orange, `[INFO]` muted) a smart auto-scroll (`userPinnedToBottom` heuristika).

**Status bar** (dolní lišta plné šířky) — `vm.statusText`, `.textSelection(.enabled)`. **Auto-collapse** když `vm.isStatusIdle` (text == idleStatus konstanta).

`.animation(.easeOut(duration: 0.20), value: statusBarShouldShow)` + `.animation(.easeInOut(duration: 0.12), value: focus)` na body root pro animované transitions (statusBar slide, VisibleFocusRing fade).

**Co je v Settings (Cmd+,):** OCR backend, výkonové steppery, timeout požadavku, `bypassInferenceCache`, `Vyčistit cache` (`role: .destructive`). + search field na top.

Monochromatický design: primary color pro dekoraci, **zelená** pro verified/selected/done, **modrá** pro primary CTA + akce, **červená** pro destructive (Přerušit, Vymazat, server odpojen). `GlassCard` má `.regularMaterial` + 0.5 pt stroke.

### `VisibleFocusRing` ViewModifier

Default macOS focus ring proti `.regularMaterial` v Light mode neviditelný. Custom modifier:
- 2 pt accent stroke 60 % opacity, RoundedRectangle(cornerRadius: 6) overlay
- `.padding(-2)`, `.allowsHitTesting(false)`
- Aplikováno na: Run, Cancel, Output, Help, Verify, Načíst

### `SettingsView` (nativní macOS Settings scene)
Settings je nativní `Settings { SettingsView(vm:) }` scéna, ale obsah nepoužívá systémový `TabView` tab strip. Kvůli chybě macOS renderování vybraného tab itemu ve světlém režimu má vlastní horní přepínač (`SettingsTab`) s explicitním `.primary` / `.secondary` textem. Okno má pevný frame **620×580 pt**, aby se vešel celý obsah bez useknutí spodních sekcí.

Struktura:
- Horní titul `Text(selectedTab.title)` + tři ikonové buttony (`speedometer`, `doc.text.viewfinder`, `externaldrive`), vybraný tab má jemný primary background + stroke.
- `selectedTabContent` switchuje mezi třemi `Form` views (`.formStyle(.grouped)`).
- **Výkon** — sekce **Souběžnost** (`maxConcurrentInference` 1–16, `maxConcurrentPDFWorkers` 1–16, `throttleDelayMs` 0–2000 ms po 50 ms) a **Model a HTTP** (`modelContextTokens` 4096–1048576 po 4096, `requestTimeoutSeconds` 60–3600 po 60 s). Změna timeoutu volá `vm.rebuildLMClient()`, protože `URLSessionConfiguration.timeoutIntervalForRequest` se po vytvoření session nedá měnit.
- **OCR** — `Picker(.inline)` na `SHOCRBackend` s vysvětlujícím footerem: Apple Vision lokálně, oMLX/VLM přes OpenAI-compatible vision požadavky, Vision→VLM jako fallback.
- **Cache** — toggle `bypassInferenceCache` + `Vyčistit cache` (`role: .destructive`), které maže per-dokument i per-inference cache.

Sdílí `vm` s hlavním oknem přes `@Bindable`; změny v Settings persistují přes `vm.persistAll()` / specializované setter metody.

### `HelpSheet`
View se strukturovanými sekcemi (Co aplikace dělá, Co si připravit, Postup, Režimy, Tipy) s reusable helpery `section / paragraph / step / bullet / mode`. Není to modální sheet — `HelpSheet` je obalen v `HelpWindowView` a zobrazen v samostatné `Window(id: "help")` scéně (viz §13), dismiss přes `@Environment(\.dismissWindow)`.

### `GlassCard`
Sdílený materiálový kontejner. `.regularMaterial` + `RoundedRectangle(cornerRadius: 10, .continuous)` + 0.5 pt stroke `Color.primary.opacity(0.06)`. Header `HStack` s ikonou (`.caption`, `.secondary`, `.symbolRenderingMode(.hierarchical)`) + titulkem (`.subheadline.weight(.semibold)`, `.secondary`). Padding 12, VStack spacing 8.

### `SHAppViewModel`
Centrální orchestrátor (`@MainActor @Observable`).

#### `PersistenceMode`
```swift
enum PersistenceMode { case persistent, scratch }
```
- **`.persistent`** (default, primary window): UserDefaults read+write přes `configStore`. Persistuje config + bookmarks + prompt history + recent folders.
- **`.scratch`** (Cmd+Shift+N windows): UserDefaults read-only pro shared assets (server registry, prompt history at init). `configStore.save` skipuje, `recordPromptInHistory` + `rememberRecentFolder` write skipují (in-memory list updateuje, persist no-op).

Init: `init(persistenceMode: PersistenceMode = .persistent)`.

#### Hlavní operace
- `verifyServer()` — ping + `/v1/models` + LM Studio's `/api/v0/models` auto-context. Po success **startServerHealthWatcher()** spustí 30 s ping loop.
- `runPreprocessing() / runExtraction() / runAll()` — single-entry guard přes `runEntered` flag, vše orchestruje `executeRun(_ work:)`.
- `cancelRun()` — propaguje `CancellationError` do pipeline.
- `clearCache()`, `refreshLog()`, `openOutput()`, `acknowledgeCompletion()`.
- `saveProjectAs() / openProject()` — Save/Open Project commands.

#### `runXxx` chování
- Vrací **typed `SHRunOutcome`** (`.success / .cancelled / .failed / .notStarted`). `executeRun` klasifikuje z return value.
- `.notStarted` nezobrazí completion badge.
- Po `.success / .cancelled / .failed` (a `!NSApp.isActive`) volá `postCompletionNotification(for:)` — Notification Center banner s "Otevřít výstup" akcí (categoryIdentifier `SHCompletionNotification.categoryID`).

#### Conflict detection (debounced)
- `parameterConflicts: [SHParameterConflict]` computed property (analyzer keyword match na promptu).
- `displayedConflicts: [SHParameterConflict]` debounced mirror — view čte tento.
- `scheduleConflictUpdate(after delayMs: Int = 400)` cancelluje pending task a registruje nový. Filtruje `dismissedConflictIDs` před assignment.
- `dismissConflict(_:)` přidá `dismissID` do `dismissedConflictIDs` (per-session set, reset v `openProject`).

#### Server health watcher
```swift
private var serverHealthTask: Task<Void, Never>?
var isVerifiedServerReachable: Bool = true
```
- 30 s `Task.sleep` smyčka, po každém pinguje `lmClient.fetchModels(server)`.
- Failure flippe `isVerifiedServerReachable = false` → `statusIndicator` pill zčervená.
- `stopServerHealthWatcher()` v `invalidateServerVerification()` (URL/server change).

#### Input folder stats (async)
- `inputFolderPdfCount: Int?`, `inputFolderPdfBytes: Int64?`, `inputFolderChipLabel: String?`
- `refreshInputFolderStats()` cancelluje předchozí `inputFolderScanTask` a startuje nový `Task.detached(priority: .userInitiated)`. Hold scoped access uvnitř task, MainActor.run zpět pro update.

#### Granular progress
- `progressState.currentlyProcessing: [String]` (max 6 inflight)
- `progressState.lastFinishedItem: String?`
- `itemStarted(_:)` / `itemFinished(_:)` callbacks z pipeline `onItemEvent`.

#### Prompt history + Recent folders
- `promptHistory: [String]` (max `promptHistoryLimit = 8`), `recordPromptInHistory()` push při Run start.
- `recentFolders: [SHFolderKind: [String]]` (max `recentFoldersLimit = 5` per kind), `rememberRecentFolder(_:kind:)` push při folder pick.
- Oba persisten do UserDefaults v `.persistent` mode (write přes `Task.detached(priority: .utility)` off-main).
- `recentFolderBookmarks: [String: Data]` (UserDefaults `SHRecentFolderBookmarks`) — trvalé security-scoped bookmarky pro nedávné cesty, aby byly v sandboxu čitelné i po startu (kde se `config.folderBookmarks` maže). Zapisuje `storeBookmark` při picku, čte/profiltruje se v `init`, `resolveScopedURL` ho používá jako fallback. Viz sekce 6 (Konfigurace a persistence).

#### Prompt library (.md soubory)
- `reloadPromptFiles(autoSelectLastLoaded:)` listuje `.md` ve `config.promptFolder` přes `SHPromptLibraryService.listFiles` (rekurzivní `FileManager.enumerator`, vč. podsložek) pod scoped přístupem; výsledek do `availablePromptFiles`.
- Volá se automaticky při změně složky promptů (`.onChange(of: promptFolder)` v `ContentView`, `autoSelectLastLoaded: false`) i explicitně tlačítkem **„Načíst"** (`true`).
- `autoSelectLastLoaded: false` = jen obnovit seznam, **nenačítat obsah** souboru (jinak by kaskáda `selectedPromptFile` → `loadPromptFile` přepsala rozeditovaný `currentPrompt` a rozbila round-trip projektu). `true` znovu otevře `lastLoadedPromptName`.

#### Save/Open Project
- `SHProjectSnapshot: Codable, Sendable` (top-level v Models layer) — folders + model picks + extractionMode + prompt + lastLoadedPromptName + schemaVersion.
- `saveProjectAs() -> URL?` — NSSavePanel, JSON encode, atomic write.
- `openProject() -> SHOpenProjectOutcome` — NSOpenPanel, sniff `schemaVersion` před decode (friendly error pro non-project JSON), `staleSandboxPaths(in:)` detekce + `successNeedsRepick` outcome.
- Reset state: `lastCompletion = nil`, `progressState = .init()`, `cachedDocuments.removeAll()`, `dismissedConflictIDs.removeAll()`.

#### Open Spice Result (import exportovaných výsledků)
- `loadedResult: SHExtractionResult?` — nil = normální pipeline režim; nenil = zobrazený načtený výsledek, pipeline tlačítka disabled (Run, Stop, mode switches, all 7 pipeline actions check `loadedResult != nil`).
- `openSpiceResultFile() -> SHOpenSpiceResultOutcome` — `NSOpenPanel` (filtrace `.json`, title "Otevřít výsledek…", zpráva odkazující na `.spice-result.json`).
- `openSpiceResultFile(_ url: URL) -> SHOpenSpiceResultOutcome` — `startAccessingSecurityScopedResource()`, `Data(contentsOf:)`, `SHJSON.decoder().decode(SHExtractionResult.self, from:)`, nastavení `loadedResult` + `statusText` ("Načteno: <patient_name> (<source_file>)"). Na failure: `loadedResult = nil`, error do statusText.
- `SHOpenSpiceResultOutcome` enum: `.success(url:)` / `.failed(error:)` / `.cancelled` (podle vzoru `SHOpenProjectOutcome`).
- `SHExportService.exportJSON` pojmenovává per-file výstupy jako `*.spice-result.json` (řádek 155 v `SHExportService.swift`) tak, aby se soubory shodovaly s UTI `DavidMasin.SpiceHarvester.result` z `Info.plist`.

#### AppIntents bridge (Shortcuts.app jako job)

`RunSpiceHarvesterIntent.perform()` volá `SHAppViewModel.runFromIntent(...)` **přímo** přes process-wide weak registry. Žádný NotificationCenter dance — odstraněn po code review, který odhalil dva race conditions (multi-vm claiming stejný `runAll` broadcast, intent observer matchoval špatný `runDidComplete`).

Klíčové komponenty:

| Komponenta | Účel |
|---|---|
| `SHAppViewModel.liveRegistry: NSHashTable<SHAppViewModel>` (weak) | Process-wide registr všech živých vmů. Init vmu se přidá, dealloc auto-prune. |
| `SHAppViewModel.runFromIntent(targetFolder:mode:promptName:)` `@MainActor` static | Resolves target → vm, brings to front, applies overrides, awaits runAll, restores, returns summary tuple |
| `SHAppViewModel.resolveIntentTarget(targetFolder:)` private static | Match by `config.inputFolder.lastPathComponent` (case-insensitive); fallback na `.persistent` vm |
| `SHAppViewModel.applyIntentParameters([AnyHashable: Any])` fileprivate | Snapshot (mode + currentPrompt + lastLoadedPromptName) → mutate. Direct .md read přes `withScopedAccess(promptFolder)` — bypassuje `loadPromptFile`'s `persistAll()` |
| `SHAppViewModel.restoreIntentOverridesIfNeeded()` private | Restore from snapshot + `persistAll` pokud něco bylo modifikováno. Volaný i z reject path |

Flow v `runFromIntent`:

```swift
1. resolveIntentTarget(targetFolder:) → vm? + failureMessage?
2. Guard !vm.isRunning && vm.canRunAll → reject early (no override applied → no UI flicker)
3. NSApp.windows.first { $0.title == vm.windowTitle }?.makeKeyAndOrderFront(nil)
4. applyIntentParameters({mode, promptName})  // snapshot + mutate
5. await vm.runAll()                          // executeRun synchronously
6. restoreIntentOverridesIfNeeded()           // rollback to snapshot
7. Read vm.lastCompletion / lastRunDocumentCount / lastRunCSVPath / statusText
8. Return summary tuple
```

`SHIntentNotifications` enum nyní obsahuje pouze `openOutput` — používá ho `SHAppDelegate` pro UN notifikační action button (delegát nemá direct vm reference, takže notifikace zůstává nejlevnější bridge).

Tracking fields v vm:
- `lastRunDocumentCount: Int` — set v `performExtraction` po `pipeline.run` (results.count)
- `lastRunCSVPath: String` — set v `performExtraction` po `exportAll`. Filename `results.csv` hardcoded v `SHExportService.exportAll`
- `intentOverrideRestore: (SHExtractionMode, String, String)?` — snapshot pre-override stavu, konzumovaný `restoreIntentOverridesIfNeeded`
- Reset summary fields na `0` / `""` na začátku `executeRun` ať `.notStarted` / `.failed` outcome neneseš starý summary

#### Multi-window collision detection + per-window naming

Cross-tab safety:
- `SHAppViewModel.activeOutputClaims: [String: SHAppViewModel]` (static `@MainActor`) — claim na výstupní složku během běhu. `executeRun` před `isRunning = true` zkontroluje, identity check `claimant !== self` ochraňuje proti omylem releasu cizího claimu. Path je normalizován přes `normalizeOutputPath` (trim + standardizingPath).
- Status text při kolizi: `"Výstupní složka je zaneprázdněná jinou záložkou (<title>) — počkej, nebo zvol jinou."` — uvádí windowTitle blokujícího vmu.

Per-window naming:
- `SHAppViewModel.windowTitle: String` — priority: input folder name → prompt stem → `scratch` indicator → bare app name. Scratch mode dopln `· scratch` suffix.
- `SHAppViewModel.windowSubtitle: String` — `<server name | host> · <mode · X / Y> | <Hotovo · N dokumentů>`. Empty když není ani server ani run state.
- `ContentView` aplikuje `.navigationTitle(vm.windowTitle)` + `.navigationSubtitle(vm.windowSubtitle)`. Reaktivní přes @Observable.

Test cleanup:
- `SHAppViewModel._resetStaticStateForTesting()` pod `#if DEBUG` čistí `activeOutputClaims` + `liveRegistry`. `SpiceHarvesterTests.init()` ho volá před každým @Test.

#### Help window — Window scene (ne sheet)

`Window("Nápověda Spice Harvester", id: "help")` v App scéně. `HelpWindowView` wrapper s `@Environment(\.dismissWindow)` pro close. Důvody:
- Sheet by se v tabbed-window groupách (Window → Sloučit okna) attachoval na sdílený parent NSWindow → bleed do všech tabů.
- `Window` (na rozdíl od `WindowGroup`) je skutečný singleton: druhé `openWindow(id: "help")` fokusne existující instance.
- `Window` má jinou window class než `WindowGroup`, takže ji macOS nemerguje s ostatními tabs.

#### Důležité chování
- `runExtraction()` automaticky spustí předzpracování, pokud ještě nejsou data v paměti
- Změna input folderu (přes picker i onChange) invaliduje `cachedDocuments`
- `lastPickedFolderParent` session-only state — další folder picker otevře rodiče minulého výběru
- `persistAllDebounced()` (300 ms) pro keystroke-driven bindings (URL, API key, prompt text), flush na `willTerminateNotification`. V `.scratch` mode no-op.

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
    HelpSheet.swift       — nápověda (Cmd+?), zobrazena v samostatné Window scéně
    SettingsView.swift    — Settings scéna (Cmd+,) s taby Výkon/OCR/Cache + search
    SHLogTextView.swift   — NSViewRepresentable wrapping NSTextView (severity coloring)
  Services/
    SHBenchmarkService.swift
    SHConfigStore.swift
    SHFileScanService.swift
    SHOpenAICompatibleClient.swift
    SHOCRProvider.swift
    SHPDFParser.swift
    SHPromptAnalyzer.swift           — + dismissID, isDismissible
    SHPromptLibraryService.swift
    SHResultSchemaValidator.swift
    SHServerRegistryStore.swift
    SHTextCleaningService.swift
  Pipeline/
    SHExtractionPipeline.swift       — + onItemEvent callback (FAST/SEARCH path)
    SHPreprocessingPipeline.swift    — + onItemEvent callback
    SHQueueManager.swift
  Cache/
    SHCacheManager.swift
    SHInferenceCache.swift           — obsahuje i actor SHEmbeddingCache
  Logging/
    SHProcessingLogger.swift
  Export/
    SHExportService.swift
  AppIntents/
    SHAppIntents.swift               — RunSpiceHarvesterIntent, OpenOutputFolderIntent, AppShortcutsProvider
  QuickLook/
    SHQuickLookPreview.swift         — provider source za #if QUICK_LOOK_EXTENSION (target chybí)
  Localizable.xcstrings              — CS source + EN translations
  ContentView.swift
  SpiceHarvesterApp.swift            — multi-scene: WindowGroup main + scratch + Settings, SHAppDelegate
  SpiceHarvester.entitlements        — Release: sandbox + user-selected files + network
  SpiceHarvesterDebug.entitlements   — Debug: + cs.* dev exceptions
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
