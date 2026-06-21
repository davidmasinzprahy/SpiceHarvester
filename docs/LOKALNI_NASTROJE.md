# Lokální nástroje (konverze a OCR)

Spice Harvester umí rozšířit vstupy a OCR pomocí externích CLI nástrojů, které
běží **lokálně** (žádný cloud). Všechny nástroje jsou **volitelné** — když
chybí, aplikace nikdy nespadne: spadne zpět na nativní zpracování (PDFKit / Apple
Vision / přímé čtení textu).

## Které nástroje k čemu slouží

| Schopnost | Vstupy | Nástroj | Homebrew formule |
|---|---|---|---|
| Office dokumenty → text | DOCX, ODT, RTF, HTML, EPUB | pandoc | `pandoc` |
| Lepší PDF text (volitelné) | PDF s textovou vrstvou | poppler (`pdftotext`) | `poppler` |
| Tabulky → CSV | XLSX, XLS | csvkit (`in2csv`) | `csvkit` |
| OCR skenů | PDF bez textové vrstvy | ocrmypdf + tesseract + ghostscript | `ocrmypdf` `tesseract` `tesseract-lang` |

Stav každého nástroje (k dispozici / verze / chybí) je vidět přímo v aplikaci:
**Nastavení → OCR → Lokální nástroje**.

## Dva způsoby provozu

### A) Vývoj — spuštění z Xcode (nástroje z `PATH`)

Při běhu z Xcode (Debug) hledá aplikace nástroje na systémové `PATH`. Stačí je
nainstalovat přes Homebrew:

```bash
brew install pandoc poppler csvkit ocrmypdf tesseract tesseract-lang
```

- `ocrmypdf` si přitáhne `tesseract` i `ghostscript` jako závislosti.
- `tesseract-lang` doplní jazyková data (vč. `ces`, `slk`, `deu`, `pol`); bez něj
  má tesseract typicky jen angličtinu.

Tohle je nejrychlejší cesta, jak si funkce vyzkoušet. Nevyžaduje žádné
bundlování ani úpravy projektu.

### B) Distribuce — nástroje bundlované do `.app`

Aby aplikace fungovala i na cizím Macu (a pod App Sandboxem) **bez** závislosti
na uživatelově Homebrew, vkládají se podepsané nástroje přímo do
`SpiceHarvester.app/Contents/Helpers/`. To řeší tři skripty v `scripts/`,
spouštěné jako Xcode **Run Script** fáze při Release buildu.

#### Build závislosti

```bash
brew install dylibbundler pandoc poppler csvkit ocrmypdf tesseract tesseract-lang ghostscript
```

`dylibbundler` přebalí dynamické knihovny do `Contents/Helpers/lib` a opraví
jejich cesty (`@executable_path`).

#### Packaging skripty

| Skript | Co vloží do `Contents/Helpers/` |
|---|---|
| `scripts/bundle_tools.sh` | `pandoc`, `pdftotext`, `pdfinfo` + dylibs |
| `scripts/bundle_python_tools.sh` | relokovatelný Python + `csvkit` + wrapper `in2csv` |
| `scripts/bundle_ocr_tools.sh` | `ocrmypdf` (do Pythonu) + `gs` + `tesseract` + `tessdata` |

Skripty jsou idempotentní a každý podepisuje vložené binárky/dylibs hardened
runtime, aby šly spustit pod sandboxem rodičovské aplikace.

#### Zapojení do Xcode

1. Vyber target **SpiceHarvester** → **Build Phases**.
2. **+** → **New Run Script Phase**, umísti ji **za** „Copy Bundle Resources".
3. Odškrtni „Based on dependency analysis".
4. Do těla vlož (v tomto pořadí — Python musí být dřív než OCR skript, který do
   něj doinstalovává ocrmypdf):

```bash
"${SRCROOT}/scripts/bundle_tools.sh"
"${SRCROOT}/scripts/bundle_python_tools.sh"
"${SRCROOT}/scripts/bundle_ocr_tools.sh"
```

5. Nastav proměnnou `PBS_URL` (build setting nebo `export` v těle před skripty)
   na [python-build-standalone](https://github.com/astral-sh/python-build-standalone/releases)
   tarball pro cílovou architekturu, např.:

```bash
export PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/<verze>/cpython-3.12.<…>-aarch64-apple-darwin-install_only.tar.gz"
```

Volitelně lze celou fázi omezit jen na Release: `if [ "$CONFIGURATION" = "Release" ]; then … fi`.

#### Ověření po buildu

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'SpiceHarvester.app' -type d 2>/dev/null | head -1)
ls "$APP/Contents/Helpers"
"$APP/Contents/Helpers/pandoc" --version | head -1
"$APP/Contents/Helpers/in2csv" --version
"$APP/Contents/Helpers/ocrmypdf" --version
```

## Důležité poznámky

- **ghostscript je AGPL.** Pokud aplikaci distribuuješ s bundlovaným `gs`,
  uveď to v licenčních podmínkách / acknowledgements aplikace. Licenční přehled
  všech bundlovaných nástrojů: [LICENCE_TRETI_STRANY.md](LICENCE_TRETI_STRANY.md);
  v aplikaci viz **Předvolby → OCR → Licence třetích stran**.
- **Notarizace:** packaging skripty odvozují codesign timestamp flag podle
  podpisové identity — ad-hoc (`-`) → `--timestamp=none` (rychlé dev buildy),
  Developer ID → `--timestamp` (secure timestamp z Apple TSA, vyžaduje síť).
  Notarizace běží jen s Developer ID, takže timestamp dostane automaticky bez
  ruční editace skriptů.
- **OCR jazyky:** jazyky pro ocrmypdf se nastavují v aplikaci (**Předvolby → OCR
  → OCR ocrmypdf**), default `ces+slk+deu+pol+eng`. Bundlují se ale jen tessdata
  pro `ces`, `slk`, `deu`, `pol`, `eng` (+ `osd` pro detekci orientace) — pro
  další jazyky doplň traineddata do `bundle_ocr_tools.sh`.
- **Velikost `.app`:** Python runtime + tesseract + ghostscript + tessdata
  výrazně zvětší výsledný balík (stovky MB).
- **Cache:** verze nástrojů vstupují do cache signatury — po upgradu nástroje se
  dotčené dokumenty přepočítají.

## Souvislosti

- Technický popis konverzní vrstvy: [Technická dokumentace](KODOVA_DOKUMENTACE.md) (sekce „Konverzní vrstva").
- Design a fázování: `docs/superpowers/specs/2026-06-13-cli-nastroje-vytezovani-design.md`.
