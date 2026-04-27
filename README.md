# SpiceHarvester

Lokální desktop aplikace pro macOS (Swift 5.10+, SwiftUI, MVVM) pro rychlé dávkové zpracování PDF zdravotnické dokumentace.

Aplikace běží na dvoufázové pipeline:
1. **Předzpracování + cache** (scan/hash/PDFKit/OCR/clean + JSON cache)
2. **Extrakce přes lokální OpenAI-compatible server** (LM Studio nebo MLX backend, uživatelem definovaný prompt a schéma výstupu)

Výchozí režim je **FAST** (bez embeddingů). Data zůstávají lokálně.

## Hlavní vlastnosti

- SwiftUI + MVVM + async/await, `@Observable`
- URLSession s retry na transient chyby (502/503/504, timeout, connection lost)
- PDFKit + Vision OCR fallback, thread-safe rendering, autoreleasepool na stránku
- Dvoustupňová **cache**:
  - per-dokument (`SHCacheManager`) — SHA-256 hash souboru → cached cleanedText
  - per-inference (`SHInferenceCache`) — hash (prompt + docs + model + cleaner verze + mode) → LLM odpověď
- **Pre-flight kontrola tokenů** v CONSOLIDATE (odhad vs. kontext modelu)
- **Auto-detekce context length** přes LM Studio native API při `Ověřit server` (u MLX/obecných serverů se nechá ručně nastavený kontext)
- **Parameter conflict detection** — prompt analyzer detekuje nesoulad režimu/embeddingů
- Security-scoped bookmarks pro přístup ke složkám napříč restarty
- Konfigurovatelná concurrency, throttle, context budget
- Průběžný log `processing.log` (cached FileHandle, tail window)
- **Výkonové odhady** na základě průměru posledního běhu
- Export: JSON (canonical), TXT, CSV (UTF-8 BOM pro Excel), per-dokument `*_raw.json` / `*_raw.csv` / `*_raw.txt`, agregátní `raw_responses.json`
- Typed `SHRunOutcome` (success / cancelled / failed / notStarted) + persistentní completion badge v UI (`Hotovo` / `Přerušeno` / `Selhalo`)
- Cooperative cancellation — `Přerušit` tlačítko propaguje `CancellationError` do pipeline

## Režimy extrakce

- **FAST**: jeden požadavek per dokument, kontext = celý `cleanedText`
- **SEARCH**: jeden požadavek per dokument, chunking + **paralelní** embeddings + výběr top-N chunků (RAG). Pokud je vybraný reranker model, SEARCH nejdřív vezme širší sadu kandidátních chunků podle embeddingů a potom je přes `/v1/rerank` přeuspořádá.
- **CONSOLIDATE**: jeden požadavek pro celý batch. Pre-flight token budget check proti kontextu modelu — pokud se batch nevejde, automaticky přechází na **map-reduce** (rozdělí dokumenty do dávek, každou zpracuje zvlášť, pak finální merge pass s deduplikací)

Fallback chování:
- SEARCH s chybou embedding endpointu → prvních N chunků bez skóre (s varováním v logu)
- SEARCH s chybou reranker endpointu → použije původní embedding ranking
- CONSOLIDATE nad budget → map-reduce (K dávek + 1 reduce = K+1 LM volání; každá fáze má vlastní cache slot, takže restart/cancel neztratí částečný progress)

Před CONSOLIDATE batchem, který je blízko kontextového limitu, se **auto-refreshuje** reálný `loaded_context_length` z LM Studia (přes `/api/v0/models`). Catches scenario, kdy uživatel mezi `Ověřit server` a `Spustit` znovu načetl model s jiným kontextem.

## Výstupní formát

Aplikace přistupuje k uživatelskému promptu jako k **jediné autoritě nad tvarem odpovědi**. Systémový prompt vkládaný do requestu je minimální (pouze: *"odpovídej validním JSON podle schématu ze zadání, bez markdownu"*). Žádné vlastní schéma se do requestu neinjectuje.

Pipeline se nejdřív pokusí dekódovat odpověď proti kanonickému schématu (`SHExtractionResult` — medicínské atributy: `patient_name`, `diagnoses`, …). **Když neprojde, raw odpověď se vždycky zachová v `rawResponse`** bez volání repair-retry (repair byl odstraněn, protože pro custom schémata produkoval falešné kanonické záznamy).

**Speciální výstupní konvence pro CSV+TXT**: pokud prompt instruuje model vrátit výstup oddělený markery `=====CSV=====` / `=====TXT=====`, export to detekuje a uloží jako samostatné `{name}_raw.csv` a `{name}_raw.txt`. Viz [docs/PROMPT_TXT_NAVOD.md](docs/PROMPT_TXT_NAVOD.md).

## Struktura projektu (aktivní runtime)

```text
SpiceHarvester/
  Models/
  ViewModels/
  Views/
    GlassCard.swift
    HelpSheet.swift
    SettingsView.swift
  Services/
  Pipeline/
  Cache/
  Logging/
  Export/
  ContentView.swift
  SpiceHarvesterApp.swift
```

Legacy implementace je archivována ve složce `Legacy/`.

## Spuštění

1. Otevři `SpiceHarvester.xcodeproj` v Xcode 16+.
2. Spusť schéma `SpiceHarvester`.
3. V levém sloupci (sekce **Složky**) nastav vstupní/výstupní/cache složku. Cestu lze nastavit přetažením složky z Finderu přímo do políčka. Po prvním výběru se další picker otevírá v rodičovském adresáři (sourozenecké projektové složky na jeden klik).
4. V sekci **Server a model** nastav lokální server:
   - LM Studio: `http://localhost:1234/v1`
   - MLX OpenAI-compatible server: typicky `http://localhost:8000/v1`
   Klikni **Ověřit** — načte seznam modelů. Po přepnutí mezi LM Studio/MLX aplikace vyčistí předchozí model selections; po ověření vyber model z nově načteného seznamu. Kontext se auto-detekuje jen u LM Studio ≥ 0.3.0; u MLX backendu status ukáže `kontext ručně` a hodnotu **Kontext modelu** nastav v **Předvolbách → Výkon** (Cmd+,) podle spuštěného modelu.
5. Vyber **Inference model**. Pokud používáš SEARCH, vyber i embedding model, který aktuální server skutečně nabízí přes `/v1/embeddings`; aplikace endpoint po výběru krátce ověří a případné selhání zobrazí ve statusbaru. Volitelně vyber **Reranker** model pro `/v1/rerank`.
6. OCR backend (Apple Vision / oMLX/VLM / Vision→VLM) se nastavuje v **Předvolbách → OCR**. Pro skenované PDF doplň **OCR/VLM** model v hlavním okně. Změna OCR backendu/modelu zahodí výsledky předzpracování v paměti a další běh je znovu vytvoří; disková cache je oddělená podle OCR nastavení.
7. Do **Prompt** vlož text ručně nebo klikni **Načíst** a vyber `.md` z pickeru.
8. Stiskni **Spustit** v horní liště okna (Cmd+R) — toolbar drží Run/Stop, Output a Help vždy na očích.

Okno se při startu přizpůsobuje aktuálnímu monitoru: výška používá celé dostupné `visibleFrame` macOS, aby se na velkém displeji zbytečně nezobrazil úvodní scrollbar; šířka je na velkém monitoru omezena na pracovní šířku UI. Hlavní okno je dvousloupcové (`HSplitView`) — vlevo konfigurace, vpravo karta Průběh + Log; rozdělovač lze tahat.

Pokud prompt nesouhlasí s aktuálním režimem (např. *"zpracuj jako jeden datový celek"* ale jedeš FAST), objeví se pod editorem **žlutý banner s jedno-klikovým přepnutím** na doporučený režim.

### Klávesové zkratky

| Akce | Zkratka |
|---|---|
| Spustit | **Cmd+R** |
| Přerušit | **Cmd+.** |
| Předzpracování | **Cmd+Shift+P** |
| Extrakce | **Cmd+Shift+E** |
| Otevřít výstup ve Finderu | **Cmd+Shift+O** |
| Předvolby (výkon, OCR, cache) | **Cmd+,** |
| Nápověda | **Cmd+?** |

## Chování persistence

- **Při startu se záměrně resetují** provozní vstupy: složky, security-scoped bookmarky, vybrané modely, text promptu, `modelContextTokens` si drží hodnotu z `Ověřit server` z minulé session.
- **Persistují se**: registry lokálních AI serverů, režim extrakce, concurrency + throttle + kontext, `bypassInferenceCache`, průměry z posledního runu (`lastRunAvg*Ms` — pro odhady v Benchmark kartě).
- **Flush při ukončení aplikace**: pending debounced `persistAllDebounced()` se při `NSApplication.willTerminateNotification` prokopne okamžitým `persistAll()`, takže force-quit během editace promptu neztratí data.

## Výkon a cache

### Inference cache

Obří úspora u iterativního ladění promptu. Klíč cache obsahuje:
- systémový prompt (interní)
- uživatelský prompt
- verzi cleaneru (`SHTextCleaningService.version`)
- seřazené SHA-256 hashe vstupních PDF
- inference model ID
- embedding model ID (jen v SEARCH)
- reranker model ID (jen v SEARCH s rerankingem)
- režim (fast/search/consolidate)
- schema version (`SHInferenceCache.schemaVersion`)

Změna kterékoli části → cache miss → nová inference. Beze změny → instant hit (statusbar ukazuje `N× cache hit`).

Toggle **"Ignorovat cache LLM odpovědí"** v **Předvolbách → Cache** (Cmd+,) ji vypne (pro non-deterministické modely).

### Výkonový odhad

Po každém úspěšném runu se ukládá `avgPerDocumentMs` a `avgPerPageMs`. Karta **Průběh** v dokončeném stavu i status bar pak před dalším runem informují o době posledního běhu; ETA při běhu se počítá z aktuálních counterů.

### Ladění concurrency

Steppery najdeš v **Předvolbách → Výkon** (Cmd+,):

1. Zvyš `Souběžné inference požadavky` postupně (2 → 3 → 4).
2. Sleduj stabilitu lokálního AI serveru.
3. Při přetížení zvyš `Throttle mezi požadavky`.
4. `Souběžné PDF/OCR workery` drž mezi `CPU/2` a `CPU`.
5. V CONSOLIDATE se `Souběžné inference` i `Throttle` ignorují (jeden požadavek).

## Čištění cache

- **Předvolby → Cache → Vyčistit cache** smaže JSON soubory per-dokument cache **i** per-inference cache.
- Nebo ručně: smaž obsah cache složky.

## Dokumentace

- Technická dokumentace: [docs/KODOVA_DOKUMENTACE.md](docs/KODOVA_DOKUMENTACE.md)
- Architektura (PlantUML): [docs/ARCHITEKTURA_PLANTUML.md](docs/ARCHITEKTURA_PLANTUML.md)
- UI design (komponenty, ikony, layout): [docs/UI_DESIGN.md](docs/UI_DESIGN.md)
- Uživatelská nápověda: [docs/NAPOVEDA_UZIVATEL.md](docs/NAPOVEDA_UZIVATEL.md)
- Terminologický slovník (kanonické pojmy v UI/dokumentaci): [docs/TERMINOLOGIE.md](docs/TERMINOLOGIE.md)
- Práce s prompty: [docs/PROMPT_TXT_NAVOD.md](docs/PROMPT_TXT_NAVOD.md)
- Legacy mapa: [Legacy/README.md](Legacy/README.md)

## Build a signing

Debug build používá `SpiceHarvester/SpiceHarvesterDebug.entitlements`, kde jsou lokální vývojové code-signing výjimky pro ladění a běh s lokálními backendy.

Release build používá `SpiceHarvester/SpiceHarvester.entitlements`, který drží jen produkční sandbox oprávnění: user-selected read/write folders a network client/server. Release konfiguraci ověříš:

```bash
xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -configuration Release -destination 'platform=macOS'
```

## Testy

```bash
xcodebuild test -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -destination 'platform=macOS'
```

Aktuálně 6 unit testů: merge výsledků, schema validace OK/FAIL, cache save/load/clear, CSV export, cleaner deduplikace.

UI testy běží ve světlém i tmavém režimu. Ověřují otevření Settings přes `Cmd+,`, existenci tabů `Výkon` / `OCR` / `Cache` a základní obsah každého tabu.
