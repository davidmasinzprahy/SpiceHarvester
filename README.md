# SpiceHarvester

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple)](https://www.apple.com/macos)
[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-orange?logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)](https://developer.apple.com/xcode/swiftui/)
[![Architecture](https://img.shields.io/badge/architecture-MVVM-success)](#)

Desktopová aplikace pro macOS pro rychlé dávkové vytěžování dat z PDF dokumentů přes OpenAI-compatible servery — ať už běží lokálně (LM Studio) nebo na vzdáleném stroji v LAN (např. **oMLX**). Aplikace je určena pro **privátní vytěžování** na soukromé síti — data opouští machine bez cloudu ani telemetrie. Původně vznikla nad zdravotnickou dokumentací — **ambulantní, propouštěcí a překladové zprávy, laboratorní výsledky** — ale díky tomu, že **schéma výstupu definuje uživatelský prompt**, ji lze použít na libovolný typ dokumentů: smlouvy, faktury, posudky, zápisy, technické zprávy, korespondenci atd.

> Data zůstávají lokálně. Žádný cloud, žádný telemetry.

Pipeline je dvoufázová:

1. **Předzpracování + cache** — scan / hash / PDFKit / OCR / clean → JSON cache
2. **Extrakce** — OpenAI-compatible API (`/chat/completions`) na libovolném backendu (LM Studio, oMLX, nebo jiný server v LAN), uživatelem definovaný prompt a schéma výstupu

Výchozí režim je **FAST** (bez embeddingů).

## Obsah

- [Rychlý start](#rychlý-start)
- [Klíčové funkce](#klíčové-funkce)
- [Výstupní formát](#výstupní-formát)
- [Bezpečnost](#bezpečnost)
- [Dokumentace](#dokumentace)

## Rychlý start

### Předpoklady

- macOS 14+ (Sonoma), Xcode 16+
- Spuštěný lokální OpenAI-compatible server:
  - **LM Studio** — typicky `http://localhost:1234/v1` (auto-detekce kontextu)
  - nebo **oMLX** — typicky `http://localhost:8000/v1` (kontext nastav ručně)
  - Libovolný OpenAI-compatible server v LAN (`http://<ip>:<port>/v1`)

### Spuštění

1. Otevři `SpiceHarvester.xcodeproj` v Xcode, spusť schéma `SpiceHarvester` (`Cmd+R`).
2. V levém sloupci nastav: složky (vstupní / výstupní / cache), server a model, prompt.
3. Stiskni **Spustit** v horní liště (`Cmd+R`).

Plný návod: [docs/NAPOVEDA_UZIVATEL.md](docs/NAPOVEDA_UZIVATEL.md).

## Klíčové funkce

- Tři režimy: **FAST** / **SEARCH** (RAG s embeddingy) / **CONSOLIDATE** (s map-reduce fallbackem)
- Dvoustupňová cache (per-dokument + per-inference) — instant hit při ladění promptu
- Pre-flight token budget check + auto-detekce context length z LM Studio API
- Multi-window: primary + scratch (Cmd+Shift+N) s nezávislým view-modelem; Save/Open Project (`Cmd+Shift+S` / `Cmd+O`)
- Clipping: Shortcuts.app integrace (plnohodnotné joby s parametry), Notification Center, Notification Center na completion (success/cancelled/failed)
- Import: **Otevřít výsledek…** (`Cmd+Shift+R`) nebo double-click `.spice-result.json` z Finderu — pipeline je během zobrazení disabled
- Lokalizace (CS + EN), Dynamic Type clamp, Reduce Motion / VoiceAware

> Podrobné klávesové zkratky: [docs/KLÁVESOVÉ_ZKRATKY.md](docs/KLÁVESOVÉ_ZKRATKY.md)
> Podrobný výkon a cache: [docs/VYKON_A_CACHE.md](docs/VYKON_A_CACHE.md)

## Výstupní formát

Uživatelský prompt je **jediná autorita nad tvarem odpovědi**. Pipeline se pokusí dekódovat odpověď proti kanonickému schématu (`SHExtractionResult`), ale **rawResponse je vždy zachován**. Custom schémata jsou plnohodnotná: prompt si je definuje sám.

Per-dokument soubory `{name}.spice-result.json` (UTI registrace `DavidMasin.SpiceHarvester.result` v `Info.plist`) — rozlišuje je Finder (✅ QuickLook preview) a lze je znovu otevřít v aplikaci přes **Otevřít výsledek…** (`Cmd+Shift+R`) nebo double-clickem z Finderu.

## Bezpečnost

- **App Sandbox** zapnutý. **`NSAllowsLocalNetworking`** v Info.plist — HTTP komunikace na serverech v LAN.
- API klíče jsou aktuálně plaintext v UserDefaults (migrace na Keychain v [P2_BACKLOG_DEFERRED.md](docs/P2_BACKLOG_DEFERRED.md)).
- Notifikační bannery obsahují pouze generický text — žádné filename, error detail nebo PHI.

## Dokumentace

| Dokument | Obsah |
|---|---|
| [Uživatelská nápověda](docs/NAPOVEDA_UZIVATEL.md) | Kompletní návod k použití |
| [Technická dokumentace](docs/KODOVA_DOKUMENTACE.md) | Architektura, pipeline, persistence, cache |
| [Architektura (PlantUML)](docs/ARCHITEKTURA_PLANTUML.md) | Blokové diagramy |
| [Klávesové zkratky](docs/KLÁVESOVÉ_ZKRATKY.md) | Rychlé příkazy a menu bar layout |
| [Výkon a cache](docs/VYKON_A_CACHE.md) | Inference cache, ladění concurrency |
| [UI design](docs/UI_DESIGN.md) | Komponenty, ikony, layout |
| [Práce s prompty](docs/PROMPT_TXT_NAVOD.md) | Šablony a CSV/TXT konvence |
| [Terminologie](docs/TERMINOLOGIE.md) | Kanonické pojmy |
| [P2 backlog](docs/P2_BACKLOG_DEFERRED.md) | Odložené funkce s implementačními poznámkami |

**Autor:** [David Mašín](https://github.com/davidmasinzprahy)
