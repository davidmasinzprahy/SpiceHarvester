# Spice Harvester

[![macOS 15.6+](https://img.shields.io/badge/macOS-15.6%2B-lightgrey?logo=apple)](https://www.apple.com/macos)
[![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)](https://developer.apple.com/xcode/swiftui/)
[![Architecture](https://img.shields.io/badge/architecture-MVVM-success)](#)

Nativní macOS aplikace pro dávkovou extrakci strukturovaných dat z dokumentů pomocí lokálního nebo LAN AI modelu.

Spice Harvester projde složku s PDF soubory nebo jinými typy souborů, vytěží z nich text, podle zadaného promptu zavolá OpenAI-kompatibilní server a uloží výsledky do JSON, CSV a TXT. Server může běžet přímo na počítači uživatele nebo v důvěryhodné LAN. Aplikace nepoužívá cloudovou službu ani telemetrii.

## K čemu slouží

- dávkové zpracování PDF a textových dokumentů
- extrakce dat podle vlastního promptu
- práce s lokálními nebo LAN modely přes LM Studio, MLX nebo jiný OpenAI-kompatibilní backend
- opakované běhy nad stejnými dokumenty díky cache
- export výsledků pro další zpracování v Excelu, Numbers, databázích nebo skriptech
- konverze office dokumentů (DOCX, ODT, RTF, HTML, EPUB) přes pandoc na text
- konverze tabulek (XLSX, XLS) na CSV přes csvkit

## Jak funguje pipeline

Zpracování má dvě fáze:

1. **Předzpracování**  
   Aplikace najde podporované dokumenty, spočítá jejich hash a vytěží text — z PDF přes PDFKit (volitelně přes `pdftotext -layout`), z office dokumentů přes pandoc, ze skenů přes OCR, nebo přímým čtením textu — a uloží vyčištěný text do cache. Skenovaná PDF bez textové vrstvy lze OCRovat lokálně volitelným backendem ocrmypdf (tesseract).

2. **Extrakce**  
   Lokální nebo LAN AI model dostane vybraný kontext dokumentu a uživatelský prompt. Odpověď se uloží v původní podobě i v aplikačním výsledkovém formátu.

## Režimy extrakce

| Režim | Použití |
|---|---|
| **FAST** | Jeden požadavek na dokument, bez embeddingů. Vhodné pro rychlé per-dokumentové extrakce. |
| **SEARCH** | Výběr relevantních částí dokumentu pomocí embeddingů. Vhodné pro delší dokumenty a cílené otázky. |
| **CONSOLIDATE** | Jeden agregovaný výstup nad celou dávkou. Vhodné pro souhrnné tabulky nebo deduplikaci napříč dokumenty. |

Výchozí režim aplikace je **SEARCH**.

## Požadavky

- macOS 15.6+
- Xcode 16+
- OpenAI-kompatibilní server dostupný lokálně nebo v LAN, například:
  - LM Studio: `http://localhost:1234/v1`
  - MLX server: `http://localhost:8000/v1`
  - vzdálený server v LAN, např. SPARK DGX
  - Ollama, vLLM, llama.cpp nebo LocalAI s kompatibilním API

## Rychlý start

1. Spusť lokální nebo LAN AI server a načti model.
2. Otevři `SpiceHarvester.xcodeproj` v Xcode.
3. Spusť schéma `SpiceHarvester`.
4. V aplikaci nastav vstupní, výstupní a cache složku.
5. Ověř server a vyber model.
6. Zadej prompt nebo načti prompt ze souboru.
7. Spusť pipeline tlačítkem **Spustit** nebo zkratkou `Cmd+R`.

Podrobný návod je v [uživatelské nápovědě](docs/NAPOVEDA_UZIVATEL.md).

## Výstupy

Aplikace zapisuje do výstupní složky:

- `results.json` - kompletní výsledky dávky
- `results.csv` - tabulkový export s UTF-8 BOM pro Excel/Numbers
- `results.txt` - čitelný textový souhrn
- `*.spice-result.json` - samostatný výsledek pro každý dokument
- `raw_responses.*` - původní odpovědi modelu, pokud jsou dostupné

Tvar odpovědi určuje uživatelský prompt. Aplikace se pokusí výsledek převést do vlastního schématu, ale původní odpověď modelu vždy zachová.

## Soukromí a bezpečnost

Spice Harvester je navržený pro lokální zpracování citlivých dokumentů.

- inference běží proti serveru zadanému uživatelem
- aplikace neposílá dokumenty do cloudu
- aplikace neobsahuje telemetrii
- notifikace neobsahují názvy souborů ani citlivé detaily
- App Sandbox je zapnutý

Pozor: API klíče jsou zatím uložené v UserDefaults jako plaintext. Migrace do Keychainu je vedená v backlogu.

## Dokumentace

| Dokument | Obsah |
|---|---|
| [Uživatelská nápověda](docs/NAPOVEDA_UZIVATEL.md) | Použití aplikace krok za krokem |
| [Technická dokumentace](docs/KODOVA_DOKUMENTACE.md) | Architektura, pipeline, cache, persistence |
| [Výkon a cache](docs/VYKON_A_CACHE.md) | Nastavení výkonu a chování cache |
| [Klávesové zkratky](docs/KLÁVESOVÉ_ZKRATKY.md) | Přehled zkratek |
| [Práce s prompty](docs/PROMPT_TXT_NAVOD.md) | Doporučený formát promptů |
| [Terminologie](docs/TERMINOLOGIE.md) | Jednotné názvosloví projektu |

## Autor

[David Mašín](https://github.com/davidmasinzprahy)
