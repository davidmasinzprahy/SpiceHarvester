# SpiceHarvester

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple)](https://www.apple.com/macos)
[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-orange?logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)](https://developer.apple.com/xcode/swiftui/)
[![Architecture](https://img.shields.io/badge/architecture-MVVM-success)](#)

Lokální desktop aplikace pro macOS pro rychlé dávkové vytěžování dat z PDF dokumentů přes lokální LLM (LM Studio nebo MLX). Původně vznikla nad zdravotnickou dokumentací — **ambulantní, propouštěcí a překladové zprávy, laboratorní výsledky** — ale díky tomu, že **schéma výstupu definuje uživatelský prompt**, ji lze použít na libovolný typ dokumentů: smlouvy, faktury, posudky, zápisy, technické zprávy, korespondenci atd.

> Data zůstávají lokálně. Žádný cloud, žádný telemetry.

Pipeline je dvoufázová:

1. **Předzpracování + cache** — scan / hash / PDFKit / OCR / clean → JSON cache
2. **Extrakce přes lokální OpenAI-compatible server** — LM Studio nebo MLX backend, uživatelem definovaný prompt a schéma výstupu

Výchozí režim je **FAST** (bez embeddingů).

## Obsah

- [Klíčové funkce](#klíčové-funkce)
- [Bezpečnost](#bezpečnost)
- [Rychlý start](#rychlý-start)
- [Režimy extrakce](#režimy-extrakce)
- [Výstupní formát](#výstupní-formát)
- [Klávesové zkratky](#klávesové-zkratky)
- [Výkon a cache](#výkon-a-cache)
- [Persistence](#persistence)
- [Dokumentace](#dokumentace)
- [Vývoj](#vývoj)
- [Autor](#autor)

## Klíčové funkce

### Pipeline a extrakce
- SwiftUI + MVVM + async/await, `@Observable`
- URLSession s retry na transient chyby (502/503/504, timeout, connection lost) a cooperative cancellation
- PDFKit + Vision OCR fallback, thread-safe rendering, autoreleasepool na stránku
- Tři režimy extrakce: **FAST** / **SEARCH** (RAG s embeddingy a volitelným rerankerem) / **CONSOLIDATE** (s map-reduce fallbackem)
- Dvoustupňová cache (per-dokument + per-inference) — instant hit při ladění promptu
- Pre-flight token budget check + auto-detekce context length z LM Studio API
- Parameter conflict detection v promptu s jednoklikovým přepnutím režimu (debounced 400 ms)
- Typed `SHRunOutcome` (success / cancelled / failed / notStarted) + persistentní completion badge v UI
- Export: JSON (canonical), TXT, CSV (UTF-8 BOM pro Excel), per-dokument `*_raw.json` / `*_raw.csv` / `*_raw.txt`, agregátní `raw_responses.json`

### UX a produktivita
- **Multi-window**: primary + scratch okna (Cmd+Shift+N) s nezávislým view-modelem; scratch okna nepersistují konfiguraci do UserDefaults. **Titulek + podtitulek per-tab** (vstupní složka · server · režim · progres) takže po sloučení do tabů poznáš každou záložku. **Kolize výstupní složky** je detekována a druhý paralelní běh do stejné cesty se zablokuje.
- **Save / Open Project** — `.spiceharvester.json` snapshot folderů, modelů, promptu a režimu (Cmd+Shift+S / Cmd+O)
- **Tab / Shift+Tab navigace** mezi aktivními tlačítky (vlastní `NSEvent` monitor, nezávislý na systémovém Keyboard Navigation)
- **Cmd+1 / Cmd+2 / Cmd+3** přepínání režimu FAST / SEARCH / CONSOLIDATE
- **Cmd+Z undo** pro Vymazat prompt přes `NSUndoManager`
- **Cmd+F** fokusuje filtr logu (case-insensitive substring)
- **Esc** uvolní textový vstup, fokus skočí na Spustit
- **Recent folders menu** vedle Vybrat (5 nejnovějších cest per slot)
- **Prompt history** (max 8) — automaticky zaznamenané prompty z úspěšných runů
- **Prompt fullscreen toggle** — dočasné rozšíření editoru přes pravý sloupec
- **Drag-out** výstupní složky z tlačítka Výstup nebo completion banneru → Finder / Slack / Mail
- **Onboarding strip** s klikatelnými kroky (Vstup / Výstup / Server / Prompt) — focusuje příslušnou kontrolu

### Stav a zpětná vazba
- **Live throughput** v Progress kartě (`12,3 dok/min · ⌀ 4,8 s/dok`)
- **Granulární progress** — viditelná aktuálně zpracovávaná položka + naposledy dokončená
- **Health watcher** — 30 s ambient ping na `/v1/models` po Ověřit; status pill zčervená při disconnectu
- **Server URL inline validace** — ⚠️ ikona u malformed Base URL bez čekání na Ověřit
- **Notification Center** na completion (success/cancelled/failed) s akcí "Otevřít výstup"
- **Shortcuts.app jako plnohodnotný job** — `Spustit extrakci` s parametry (režim, název promptu, cílová záložka), čeká na dokončení a vrátí cestu k `results.csv` pro řetězení s dalšími akcemi (mail, Slack, git push…). Plánovatelné přes Automation tab. Cílení podle vstupní složky umožní paralelní joby v různých záložkách. + Spotlight + Siri
- **Window position persistence** — manuální resize/move přežívá restart
- **Status bar** auto-collapse když není runtime status
- **VSplitView** s tažitelnými dělítky mezi Prompt / Průběh / Log

### Sandbox a integrace
- Security-scoped bookmarks pro persistentní přístup ke složkám napříč restarty
- Konfigurovatelná concurrency, throttle, context budget
- Lokalizace přes String Catalog (CS source + EN ready, fallback na CS)
- Settings search (Cmd+,) — fulltextový skok na příslušný tab
- Dynamic Type clamp `.medium…accessibility3`
- Reduce Motion / VoiceOver composite elements (banners) / focus ring overlay

## Rychlý start

### Předpoklady

- macOS 14+ (Sonoma)
- Xcode 16+
- Spuštěný lokální OpenAI-compatible server:
  - **LM Studio** — typicky `http://localhost:1234/v1` (auto-detekce kontextu)
  - nebo **MLX OpenAI-compatible server** — typicky `http://localhost:8000/v1` (kontext nastav ručně v Předvolbách)

### Spuštění

1. Otevři `SpiceHarvester.xcodeproj` v Xcode.
2. Spusť schéma `SpiceHarvester` (`Cmd+R`).
3. V levém sloupci nastav:
   - **Složky** — vstupní / výstupní / cache složku (lze přetáhnout z Finderu)
   - **Server a model** — adresu, klikni **Ověřit**, vyber inference model. Po přepnutí mezi LM Studio / MLX se model selections vyčistí. Pro SEARCH vyber i embedding model (aplikace endpoint krátce ověří) a volitelně reranker pro `/v1/rerank`.
   - **Prompt** — vlož ručně nebo přes **Načíst** z `.md`
4. OCR backend (Apple Vision / VLM / Vision→VLM) se nastavuje v **Předvolbách → OCR** (`Cmd+,`). Pro skenované PDF doplň **OCR/VLM** model v hlavním okně.
5. Stiskni **Spustit** v horní liště (`Cmd+R`).

Pokud prompt nesouhlasí s aktuálním režimem, objeví se pod editorem **žlutý banner s jednoklikovým přepnutím** na doporučený režim.

Plný uživatelský návod: [docs/NAPOVEDA_UZIVATEL.md](docs/NAPOVEDA_UZIVATEL.md).

## Režimy extrakce

| Režim | Strategie | Kdy použít |
|---|---|---|
| **FAST** | 1 request per dokument, kontext = celý `cleanedText` | Krátké dokumenty, bez embeddingů |
| **SEARCH** | 1 request per dokument, chunking + paralelní embeddings + top-N (volitelný reranker přes `/v1/rerank`) | Dlouhé dokumenty, stačí relevantní pasáže |
| **CONSOLIDATE** | 1 request pro celý batch s pre-flight token budget checkem | Dedupování / shrnutí napříč dokumenty |

**Fallback chování:**

- SEARCH s chybou embedding endpointu → prvních N chunků bez skóre (varování v logu)
- SEARCH s chybou reranker endpointu → použije původní embedding ranking
- CONSOLIDATE nad budget → **map-reduce** (K dávek + 1 reduce = K+1 LM volání; každá fáze má vlastní cache slot, takže restart/cancel neztratí částečný progress)

Před CONSOLIDATE batchem blízko kontextového limitu se reálný `loaded_context_length` auto-refreshuje z LM Studia (přes `/api/v0/models`) — pokrývá scénář, kdy uživatel mezi `Ověřit server` a `Spustit` znovu načetl model s jiným kontextem.

## Výstupní formát

Aplikace přistupuje k uživatelskému promptu jako k **jediné autoritě nad tvarem odpovědi**. Systémový prompt vkládaný do requestu je minimální (pouze: *„odpovídej validním JSON podle schématu ze zadání, bez markdownu"*). Žádné vlastní schéma se do requestu neinjectuje.

Pipeline se nejdřív pokusí dekódovat odpověď proti vestavěnému kanonickému schématu (`SHExtractionResult` — historicky tvořené medicínskými atributy `patient_name`, `diagnoses`, …, ale slouží jen jako fallback dekodér). **Když odpověď proti němu neprojde, raw text se vždy zachová v `rawResponse`** bez volání repair-retry (repair byl odstraněn, protože nad custom schématy generoval falešné kanonické záznamy). Custom schémata jsou tím pádem plnohodnotná: prompt si je definuje sám a aplikace je propíše do exportu beze ztráty.

**Speciální výstupní konvence pro CSV+TXT:** pokud prompt instruuje model vrátit výstup oddělený markery `=====CSV=====` / `=====TXT=====`, export to detekuje a uloží jako samostatné `{name}_raw.csv` a `{name}_raw.txt`. Viz [docs/PROMPT_TXT_NAVOD.md](docs/PROMPT_TXT_NAVOD.md).

## Klávesové zkratky

| Akce | Zkratka |
|---|---|
| Spustit | `Cmd+R` |
| Přerušit | `Cmd+.` |
| Předzpracování | `Cmd+Shift+P` |
| Extrakce | `Cmd+Shift+E` |
| Otevřít výstup ve Finderu | `Cmd+Shift+O` |
| **Otevřít projekt…** | `Cmd+O` |
| **Uložit projekt jako…** | `Cmd+Shift+S` |
| **Nové okno (scratch)** | `Cmd+Shift+N` |
| **Režim FAST / SEARCH / CONSOLIDATE** | `Cmd+1` / `Cmd+2` / `Cmd+3` |
| **Fokus filtru logu** | `Cmd+F` |
| **Zpět (po Vymazat prompt)** | `Cmd+Z` |
| Předvolby (výkon, OCR, cache) | `Cmd+,` |
| Nápověda | `Cmd+?` |

**Tab navigace** přes hlavní tlačítka funguje i bez systémového zapnutí *Keyboard Navigation* — aplikace má vlastní `NSEvent` monitor, který Tab/Shift+Tab cykluje pouze přes aktivní (neszedisabledované) tlačítka. **Esc** uvolní textové pole a skočí na Spustit.

### Menu bar layout

| Menu | Položky |
|---|---|
| **File** | Nové okno (scratch) `Cmd+Shift+N` · Otevřít projekt… `Cmd+O` · Otevřít nedávné › … · Uložit projekt jako… `Cmd+Shift+S` · Otevřít výstup ve Finderu `Cmd+Shift+O` |
| **Pipeline** *(custom top-level)* | Spustit `Cmd+R` · Přerušit `Cmd+.` · Předzpracování `Cmd+Shift+P` · Extrakce `Cmd+Shift+E` · Režim FAST / SEARCH / CONSOLIDATE `Cmd+1/2/3` · Znovu ověřit zdraví serveru |
| **Help** | Nápověda Spice Harvester `Cmd+?` |

Pipeline akce mají vlastní top-level menu (vzor: Xcode Product menu, Logic Pro Track menu) — File menu drží jen project/document operace.

## Výkon a cache

### Inference cache

Obří úspora u iterativního ladění promptu. Klíč cache obsahuje:

- systémový prompt (interní) + uživatelský prompt
- verzi cleaneru (`SHTextCleaningService.version`)
- seřazené SHA-256 hashe vstupních PDF
- inference model ID (+ embedding / reranker model ID v SEARCH)
- režim (fast / search / consolidate)
- schema version (`SHInferenceCache.schemaVersion`)

Změna kterékoli části → cache miss → nová inference. Beze změny → instant hit (status bar ukazuje `N× cache hit`).

Toggle **„Ignorovat cache LLM odpovědí"** v **Předvolbách → Cache** (`Cmd+,`) ji vypne (pro non-deterministické modely).

### Výkonový odhad

Po každém úspěšném runu se ukládá `avgPerDocumentMs` a `avgPerPageMs`. Karta **Průběh** v dokončeném stavu i status bar pak před dalším runem informují o době posledního běhu; ETA při běhu se počítá z aktuálních counterů.

### Ladění concurrency

Steppery v **Předvolbách → Výkon** (`Cmd+,`):

1. Zvyš `Souběžné inference požadavky` postupně (2 → 3 → 4).
2. Sleduj stabilitu lokálního AI serveru.
3. Při přetížení zvyš `Throttle mezi požadavky`.
4. `Souběžné PDF/OCR workery` drž mezi `CPU/2` a `CPU`.
5. V CONSOLIDATE se `Souběžné inference` i `Throttle` ignorují (jeden požadavek).

### Čištění cache

- **Předvolby → Cache → Vyčistit cache** smaže JSON soubory per-dokument cache **i** per-inference cache.
- Nebo ručně: smaž obsah cache složky.

## Bezpečnost

### Sandbox a entitlementy
- **App Sandbox** zapnutý (`com.apple.security.app-sandbox`).
- **`NSAllowsLocalNetworking`** — ATS nastavení v Info.plist build settings (`INFOPLIST_KEY_NSAppTransportSecurity` v project.pbxproj), **ne** entitlement v `.entitlements` souboru. Povoluje ATS pouze pro local network (LM Studio na localhost). Zpřísněno z `NSAllowsArbitraryLoads`, který by povoloval libovolné HTTP cíle. (`.entitlements` obsahuje jen app-sandbox, files.user-selected.read-write, network.client a network.server.)
- **`com.apple.security.files.user-selected.read-write`** — přístup pouze ke složkám, které uživatel explicitně vybral přes NSOpenPanel + jejich security-scoped bookmarks.
- **`com.apple.security.network.client`** — odchozí HTTP požadavky na LM server.
- **`com.apple.security.network.server`** — historicky vyžadováno pro localhost connections v některých macOS verzích. Pro pure-client app technicky nadbytečné, ale ponecháno z důvodu kompatibility.

### Citlivá data
- **API klíče** v `SHServerConfig.apiKey` jsou aktuálně **plaintext v UserDefaults** (sandbox container `~/Library/Containers/.../Preferences/`). Pro lokální LM Studio (default bez auth) je pole prázdné, takže expozice je teoretická. Pro hosted OpenAI-compatible proxy s bearer tokenem je třeba pamatovat, že token přežívá v UserDefaults. Migrace na Keychain je v [docs/P2_BACKLOG_DEFERRED.md](docs/P2_BACKLOG_DEFERRED.md).
- **Notifikační banner** (success/cancelled/failed) obsahuje pouze **generický text** — žádné filename, error detail nebo PHI. Detaily ostávají v hlavním okně. Důvod: notifikace jsou viditelné na lock screenu i ostatním lidem.
- **Log v `processing.log`** může obsahovat names PDF souborů, error stacks a (v medical-records kontextu) PHI fragmenty. Soubor žije ve výstupní složce uživatele — uživatel je odpovědný za její ochranu.
- **Pasteboard** přes Cmd+C v log card nebo drag-out z Output button — uživatelem iniciovaný kopírovací akt; obsah jde mimo aplikaci (Slack, Mail, Finder) podle vůle uživatele.

### Quick Look extension (deferred)
Source je připravený s HTML escape pro `source_file` title (XSS guard) — viz [SHQuickLookPreview.swift](SpiceHarvester/QuickLook/SHQuickLookPreview.swift). Aktivace vyžaduje nový Xcode target.

## Persistence

### Persistent (primary) window
- **Při startu se záměrně resetují** provozní vstupy: složky, security-scoped bookmarky, vybrané modely, text promptu. `modelContextTokens` si drží hodnotu z `Ověřit server` z minulé session.
- **Persistují se**: registry lokálních AI serverů, režim extrakce, concurrency + throttle + kontext, `bypassInferenceCache`, průměry z posledního runu (`lastRunAvg*Ms` — pro odhady v Benchmark kartě), prompt history (max 8), recent folders per slot (max 5).
- **Flush při ukončení aplikace**: pending debounced `persistAllDebounced()` se při `NSApplication.willTerminateNotification` prokopne okamžitým `persistAll()`, takže force-quit během editace promptu neztratí data.

### Scratch (secondary) window — Cmd+Shift+N
- View-model je inicializován s `PersistenceMode.scratch`.
- **`configStore.save` skipuje** — scratch okno nepřepíše primary's UserDefaults config slot.
- **Server registry sdílen** přes `serverStore.saveServers` — server přidaný ve scratch je dostupný i v primary.
- **Prompt history a Recent folders** zůstávají per-session (in-memory list updateuje, write skip).
- Pro persistování scratch konfigu uživatel použije **Uložit projekt jako…** (Cmd+Shift+S).

### Project files (`.spiceharvester.json`)
- `SHProjectSnapshot` Codable struct — folders, model picks, mode, prompt, lastLoadedPromptName.
- **Vyloučeno**: server registry (sdíleno globálně), runtime state, performance prefs.
- Open Project detekuje cesty bez stored security-scoped bookmarku a vyzve k re-pick (sandbox není možné obejít).

## Dokumentace

| Dokument | Obsah |
|---|---|
| [Uživatelská nápověda](docs/NAPOVEDA_UZIVATEL.md) | UI, klávesové zkratky, multi-window, projekty, OCR, řešení problémů |
| [Technická dokumentace](docs/KODOVA_DOKUMENTACE.md) | Architektura, pipeline, persistence, cache, AppIntents, multi-window |
| [UI design](docs/UI_DESIGN.md) | Komponenty, ikony, layout, focus ring, drag handles |
| [Architektura (PlantUML)](docs/ARCHITEKTURA_PLANTUML.md) | Diagramy |
| [Práce s prompty](docs/PROMPT_TXT_NAVOD.md) | Šablony a CSV/TXT konvence |
| [Terminologie](docs/TERMINOLOGIE.md) | Kanonické pojmy v UI/dokumentaci |
| [P2 backlog](docs/P2_BACKLOG_DEFERRED.md) | Quick Look extension, iCloud Drive, plný DocumentGroup — implementační poznámky |
| [Legacy mapa](Legacy/README.md) | Stará implementace |

## Vývoj

### Struktura projektu (aktivní runtime)

```text
SpiceHarvester/
├─ Models/                 # Codable structs (SHAppConfig, SHExtractionResult, SHProgressViewState)
├─ ViewModels/
│  └─ SHAppViewModel.swift # @Observable @MainActor — config, runtime, persistence
├─ Views/
│  ├─ GlassCard.swift      # Compact Glass card wrapper
│  ├─ HelpSheet.swift      # Help view (zobrazen v samostatné Window scéně, ne sheet)
│  ├─ SettingsView.swift   # Cmd+, sheet (Výkon / OCR / Cache, search field)
│  └─ SHLogTextView.swift  # NSViewRepresentable wrapping NSTextView (severity colored)
├─ Services/               # SHPromptAnalyzer, SHFileScanService, SHTextCleaningService, …
├─ Pipeline/               # SHPreprocessingPipeline, SHExtractionPipeline (FAST/SEARCH/CONSOLIDATE)
├─ Cache/                  # SHCacheManager (per-doc), SHInferenceCache (per-call)
├─ Logging/                # SHProcessingLogger
├─ Export/                 # SHExportService (JSON/CSV/TXT)
├─ AppIntents/
│  └─ SHAppIntents.swift   # RunSpiceHarvesterIntent, OpenOutputFolderIntent, AppShortcutsProvider
├─ QuickLook/
│  └─ SHQuickLookPreview.swift  # Provider source za #if QUICK_LOOK_EXTENSION (target chybí, viz P2 backlog)
├─ Localizable.xcstrings   # CS source + EN překlady
├─ ContentView.swift       # HSplitView root, runRow, focus management
└─ SpiceHarvesterApp.swift # Scenes: WindowGroup primary + scratch + Settings + Help Window; SHAppDelegate
```

Legacy implementace je archivována ve složce `Legacy/`.

### Okno a layout

Okno se při startu přizpůsobuje aktuálnímu monitoru: výška používá celé dostupné `visibleFrame` macOS, aby se na velkém displeji nezobrazil úvodní scrollbar; šířka je na velkém monitoru omezena na pracovní šířku UI. **Window position se persistuje** přes `setFrameAutosaveName` — manuální resize/move přežívá restart.

Hlavní okno je dvousloupcové (`HSplitView`):
- **Vlevo (konfigurace + ovládání):** Onboarding strip → Složky → Server → Modely a režim → divider → Run row (status pill + Spustit/Výstup/Nápověda)
- **Vpravo (workspace + monitoring):** Notifikace → `VSplitView` { Prompt → Průběh → Log } s tažitelnými dělítky a viditelnými drag-handle pily

Sekundární scratch okna (Cmd+Shift+N) sdílejí stejný layout, ale s vlastním view-modelem.

### Build a signing

Debug konfigurace používá `SpiceHarvester/SpiceHarvesterDebug.entitlements` (lokální vývojové code-signing výjimky pro ladění a běh s lokálními backendy).

Release konfigurace používá `SpiceHarvester/SpiceHarvester.entitlements`, který drží jen produkční sandbox oprávnění: user-selected read/write folders a network client/server.

```bash
xcodebuild build \
  -project SpiceHarvester.xcodeproj \
  -scheme SpiceHarvester \
  -configuration Release \
  -destination 'platform=macOS'
```

### Testy

```bash
xcodebuild test \
  -project SpiceHarvester.xcodeproj \
  -scheme SpiceHarvester \
  -destination 'platform=macOS'
```

Aktuálně 11 unit testů (+ 2 integrační): merge výsledků, schema validace OK/FAIL, cache save/load/clear, CSV export, cleaner deduplikace, obnova `recentProjectURLs` z UserDefaults, `openProject` zapomene URL při nevalidním JSON, `recheckServerNow` bez vybraného serveru a cross-window observer recent-projects.

UI testy běží ve světlém i tmavém režimu. Ověřují otevření Settings přes `Cmd+,`, existenci tabů `Výkon` / `OCR` / `Cache` a základní obsah každého tabu.

## Autor

**David Mašín** — [@davidmasinzprahy](https://github.com/davidmasinzprahy)
