# Integrace lokálních CLI nástrojů do vytěžovací pipeline — design

Datum: 2026-06-13
Autor: David Mašín (s asistencí Claude Code)
Stav: schváleno k implementačnímu plánu

## Cíl

Rozšířit lokální vytěžování dat Spice Harvesteru o externí CLI nástroje
(pandoc, poppler, csvkit, ocrmypdf + tesseract), aby aplikace zvládla více
vstupních formátů a kvalitnější extrakci textu — vše lokálně, bez cloudu a
telemetrie, při zachování App Sandboxu.

Mimo rozsah: `glow` (terminálový markdown renderer; do GUI extrakční aplikace
nedává smysl).

## Výchozí stav

- Podporované vstupy: `pdf, txt, text, md, markdown, csv, tsv, json`
  (`SHFileScanService.supportedDocumentExtensions`).
- PDF text přes PDFKit (`SHPDFParser`), OCR přes Vision (`SHVisionOCRProvider`),
  případně přes remote vision model, s fallback řetězcem (`SHFallbackOCRProvider`).
- Vše běží in-process; nic se nešelluje ven.
- App Sandbox je zapnutý (`com.apple.security.app-sandbox = true`); entitlementy:
  user-selected read-write, network client, network server.

## Dostupné nástroje (ověřeno na vývojovém stroji)

| Nástroj | Binárky | Stav |
|---|---|---|
| poppler | `pdftotext`, `pdfimages`, `pdfinfo` | dostupné |
| pandoc | `pandoc` | dostupné |
| csvkit | `in2csv`, `csvlook`, … | dostupné (Python balík) |
| ocrmypdf | `ocrmypdf` | dostupné (Python aplikace) |
| tesseract | `tesseract` + `tessdata` | dostupné, 163 jazyků vč. `ces, slk, deu, pol, eng` |
| glow | — | **mimo rozsah** |

## Zásadní omezení: App Sandbox

Sandboxovaná aplikace nemůže přes `Process`/exec spustit binárky z
`/opt/homebrew/bin`. **Zvolené řešení: bundlovat podepsané binárky do `.app`** a
volat je tak, aby potomci dědili sandbox kontejner (entitlement
`com.apple.security.inherit`). ocrmypdf navíc spouští ghostscript a tesseract
jako vnoučata — i ta musí být podepsaná s inherit.

## Architektura

Nová **konverzní (ingestion) vrstva** běží *před* stávajícím
`SHPreprocessingPipeline.parseText`. Libovolný vstupní formát se normalizuje na
text/stránky; zbytek pipeline (hash, cache, cleaning, extrakce) zůstává beze
změny.

```
soubor → SHDocumentConverter (routuje podle přípony / textové vrstvy)
            ├ docx/odt/rtf/html/htm/epub → pandoc            → markdown/text
            ├ xlsx/xls                   → in2csv            → CSV
            ├ pdf (textová vrstva)       → pdftotext -layout (opt-in) / PDFKit (default)
            ├ pdf (sken, bez vrstvy)     → ocrmypdf+tesseract → searchable PDF → pdftotext
            └ txt/md/csv/tsv/json        → nativně (beze změny)
         → SHPreprocessingPipeline.processOne (cache → cleaning → extrakce)
```

## Komponenty

Každá komponenta má jeden účel, jasné rozhraní a lze ji testovat samostatně.

| Komponenta | Účel | Závisí na |
|---|---|---|
| `SHToolRuntime` | najde bundlovanou binárku (`.app/Contents/Helpers/`), fallback na `PATH` (dev); spustí přes `Process` s timeoutem, cancellation a capture stdout/stderr | Foundation |
| `SHToolRegistry` | health-check — která binárka existuje a v jaké verzi; vstup pro Settings a pro cache signaturu | `SHToolRuntime` |
| `SHDocumentConverter` | routuje soubor → správný nástroj → normalizovaný text/stránky; při chybějícím nástroji fallback na nativní cestu | `SHToolRuntime`, `SHToolRegistry` |
| `SHFileScanService` (rozšíření) | přidat přípony: `docx, odt, rtf, html, htm, epub, xlsx, xls` | — |
| `SHPreprocessingPipeline` (úprava) | volat converter v `parseText`; do `preprocessingSignature` přidat verze nástrojů | `SHDocumentConverter` |
| Settings panel (rozšíření) | přepínače per-schopnost + stav nástrojů (verze / chybí) | `SHToolRegistry` |

### `SHToolRuntime`
- Rozhraní: `run(tool: SHTool, arguments: [String], stdin: Data?, timeout: TimeInterval) async throws -> SHToolResult` (stdout, stderr, exit code).
- Hledání binárky: nejprve `Bundle.main` (`Contents/Helpers/<tool>`), pak `PATH`.
- Respektuje `Task.checkCancellation()`; po cancellation proces ukončí.

### `SHToolRegistry`
- `status(for: SHTool) -> SHToolStatus` (`.available(version:)` / `.missing`).
- Výsledky cachuje po dobu běhu; dotaz na verzi spouští `--version`.
- `signatureComponent() -> String` — stabilní řetězec verzí pro cache.

### `SHDocumentConverter`
- `convert(fileURL: URL) async throws -> SHPDFParseResult` (sjednocený tvar
  s existující PDFKit cestou: `rawPages`, `hasTextLayer`, `pageCount`).
- Routing podle přípony; PDF dále podle přítomnosti textové vrstvy.
- Fallback: chybí-li potřebný nástroj, vrátí výsledek nativní cesty (PDFKit/Vision/UTF-8) a zaloguje to.

## Datový tok a cache

- Converter vrací `SHPDFParseResult`, takže `processOne` nemusí měnit svůj kontrakt.
- `preprocessingSignature` ponese verze relevantních nástrojů → změna verze
  (např. tesseract) automaticky invaliduje a přepočítá dotčené dokumenty.
- OCR přes ocrmypdf nastaví `usedOCR = true` v `SHDocumentMetadata` stejně jako
  dnešní Vision cesta.

## Chování při chybách

- **Graceful degradation:** chybějící nástroj nikdy neshodí pipeline; converter
  spadne zpět na nativní cestu a událost zaloguje (`phase: "CONVERT"`).
- **Timeout / nenulový exit:** zaloguje stderr, dokument se zpracuje nativní
  cestou, pokud existuje, jinak se přeskočí (stejně jako dnešní chyby preprocessingu).
- **Cancellation:** běžící proces se ukončí, dokument se nezacachuje.

## Soukromí a bezpečnost

- Žádné nové síťové volání; vše lokální — souznívá s designem aplikace.
- Bundlované binárky podepsané stejným Team ID; potomci dědí sandbox.
- ghostscript je AGPL → poznámka v licenčním souboru aplikace.

## Packaging

Build skripty v `scripts/` + Xcode run-script fáze vloží do `.app`:

- **pandoc** — jedna staticky linkovaná binárka (~150 MB).
- **poppler** — `pdftotext`, `pdfinfo` + dylibs (fix rpath přes `dylibbundler`).
- **Python runtime** — relocatable (python-build-standalone) + `pip install
  ocrmypdf csvkit` (kvůli `in2csv` a `ocrmypdf`).
- **ghostscript**, **tesseract** + `tessdata` pouze pro `ces, slk, deu, pol, eng`
  (~50 MB místo všech 163 jazyků).

Dopad: velikost `.app` ~500 MB–1 GB; složitější codesign a notarizace.

## Rozhodnutí (defaulty)

- **PDF s textovou vrstvou:** `pdftotext -layout` je **opt-in**; default zůstává
  PDFKit, aby se nezměnilo stávající chování.
- **tessdata:** bundlovat jen pět jazyků (`ces, slk, deu, pol, eng`).

## Fázování

Každá fáze je samostatně dodatelná a testovatelná.

1. **Fáze 1 — základ + levné výhry:** `SHToolRuntime`, `SHToolRegistry`,
   packaging infrastruktura, **pandoc** (office dokumenty), **poppler**
   (opt-in lepší PDF text). Postaví celý mechanismus volání nástrojů.
2. **Fáze 2 — tabulky:** Python runtime + **csvkit** (`in2csv`) pro XLSX/XLS → CSV.
3. **Fáze 3 — OCR skenů:** **ocrmypdf + tesseract + ghostscript**. Nejdražší,
   částečně duplikuje Vision OCR — proto naposled.

## Testování

- `SHToolRuntime`: spuštění, timeout, cancellation, capture stderr (fake/echo tool).
- `SHToolRegistry`: detekce dostupnosti a verze; fallback při chybějícím nástroji.
- `SHDocumentConverter`: routing per přípona; korektní fallback na nativní cestu.
- Pipeline integrace: rozšířený sken najde nové přípony; cache signatura reaguje
  na změnu verze nástroje.
- Fixtures: malé vzorky docx/xlsx/scan-pdf v testovacích datech.

## Otevřené body k ověření při implementaci

- Praktické ověření, že sandboxovaný `.app` skutečně spustí bundlovanou
  binárku s `com.apple.security.inherit` (a vnoučata u ocrmypdf).
- Strategie fix rpath pro poppler/tesseract dylibs (`dylibbundler` vs ruční).
