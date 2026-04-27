# SpiceHarvester

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple)](https://www.apple.com/macos)
[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-orange?logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)](https://developer.apple.com/xcode/swiftui/)
[![Architecture](https://img.shields.io/badge/architecture-MVVM-success)](#)

Lokální desktop aplikace pro macOS pro rychlé dávkové vytěžování dat z PDF dokumentů přes lokální LLM (LM Studio nebo MLX). Původně vznikla nad zdravotnickou dokumentací, ale díky tomu, že **schéma výstupu definuje uživatelský prompt**, ji lze použít na libovolný typ dokumentů — smlouvy, faktury, posudky, zápisy, technické zprávy, korespondenci atd.

> Data zůstávají lokálně. Žádný cloud, žádný telemetry.

Pipeline je dvoufázová:

1. **Předzpracování + cache** — scan / hash / PDFKit / OCR / clean → JSON cache
2. **Extrakce přes lokální OpenAI-compatible server** — LM Studio nebo MLX backend, uživatelem definovaný prompt a schéma výstupu

Výchozí režim je **FAST** (bez embeddingů).

## Obsah

- [Klíčové funkce](#klíčové-funkce)
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

- SwiftUI + MVVM + async/await, `@Observable`
- URLSession s retry na transient chyby (502/503/504, timeout, connection lost) a cooperative cancellation
- PDFKit + Vision OCR fallback, thread-safe rendering, autoreleasepool na stránku
- Tři režimy extrakce: **FAST** / **SEARCH** (RAG s embeddingy a volitelným rerankerem) / **CONSOLIDATE** (s map-reduce fallbackem)
- Dvoustupňová cache (per-dokument + per-inference) — instant hit při ladění promptu
- Pre-flight token budget check + auto-detekce context length z LM Studio API
- Parameter conflict detection v promptu s jednoklikovým přepnutím režimu
- Security-scoped bookmarks pro persistentní přístup ke složkám napříč restarty
- Konfigurovatelná concurrency, throttle, context budget
- Typed `SHRunOutcome` (success / cancelled / failed / notStarted) + persistentní completion badge v UI
- Export: JSON (canonical), TXT, CSV (UTF-8 BOM pro Excel), per-dokument `*_raw.json` / `*_raw.csv` / `*_raw.txt`, agregátní `raw_responses.json`

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
| Předvolby (výkon, OCR, cache) | `Cmd+,` |
| Nápověda | `Cmd+?` |

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

## Persistence

- **Při startu se záměrně resetují** provozní vstupy: složky, security-scoped bookmarky, vybrané modely, text promptu. `modelContextTokens` si drží hodnotu z `Ověřit server` z minulé session.
- **Persistují se**: registry lokálních AI serverů, režim extrakce, concurrency + throttle + kontext, `bypassInferenceCache`, průměry z posledního runu (`lastRunAvg*Ms` — pro odhady v Benchmark kartě).
- **Flush při ukončení aplikace**: pending debounced `persistAllDebounced()` se při `NSApplication.willTerminateNotification` prokopne okamžitým `persistAll()`, takže force-quit během editace promptu neztratí data.

## Dokumentace

| Dokument | Obsah |
|---|---|
| [Uživatelská nápověda](docs/NAPOVEDA_UZIVATEL.md) | UI, klávesové zkratky, OCR, řešení problémů |
| [Technická dokumentace](docs/KODOVA_DOKUMENTACE.md) | Architektura, pipeline, persistence, cache |
| [UI design](docs/UI_DESIGN.md) | Komponenty, ikony, layout |
| [Architektura (PlantUML)](docs/ARCHITEKTURA_PLANTUML.md) | Diagramy |
| [Práce s prompty](docs/PROMPT_TXT_NAVOD.md) | Šablony a CSV/TXT konvence |
| [Terminologie](docs/TERMINOLOGIE.md) | Kanonické pojmy v UI/dokumentaci |
| [Legacy mapa](Legacy/README.md) | Stará implementace |

## Vývoj

### Struktura projektu (aktivní runtime)

```text
SpiceHarvester/
├─ Models/
├─ ViewModels/
├─ Views/
│  ├─ GlassCard.swift
│  ├─ HelpSheet.swift
│  └─ SettingsView.swift
├─ Services/
├─ Pipeline/
├─ Cache/
├─ Logging/
├─ Export/
├─ ContentView.swift
└─ SpiceHarvesterApp.swift
```

Legacy implementace je archivována ve složce `Legacy/`.

### Okno

Okno se při startu přizpůsobuje aktuálnímu monitoru: výška používá celé dostupné `visibleFrame` macOS, aby se na velkém displeji nezobrazil úvodní scrollbar; šířka je na velkém monitoru omezena na pracovní šířku UI. Hlavní okno je dvousloupcové (`HSplitView`) — vlevo konfigurace, vpravo karta Průběh + Log; rozdělovač lze tahat.

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

Aktuálně 6 unit testů: merge výsledků, schema validace OK/FAIL, cache save/load/clear, CSV export, cleaner deduplikace.

UI testy běží ve světlém i tmavém režimu. Ověřují otevření Settings přes `Cmd+,`, existenci tabů `Výkon` / `OCR` / `Cache` a základní obsah každého tabu.

## Autor

**David Mašín** — [@davidmasinzprahy](https://github.com/davidmasinzprahy)
