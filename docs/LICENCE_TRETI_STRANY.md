# Licence nástrojů třetích stran

Spice Harvester volitelně používá externí CLI nástroje pro rozšířené zpracování
vstupů a OCR. Tyto nástroje se spouštějí jako **samostatné procesy** (subprocess
přes `PATH` / bundlované v `Contents/Helpers/`), nelinkují se do aplikace.
Z hlediska licencí jde o tzv. *mere aggregation* — Spice Harvester proto
nepřebírá copyleftové licence těchto nástrojů. Při **distribuci** aplikace
s bundlovanými binárkami ale platí povinnosti dané jejich licencemi (zejména
zpřístupnění zdrojového kódu u GPL/AGPL nástrojů).

## Přehled

| Nástroj | Použití | Licence | Zdrojový kód |
|---|---|---|---|
| pandoc | konverze office dokumentů (DOCX/ODT/RTF/HTML/EPUB) | GPL-2.0-or-later | https://github.com/jgm/pandoc |
| poppler (`pdftotext`, `pdfinfo`) | extrakce textu z PDF | GPL-2.0 / GPL-3.0 | https://gitlab.freedesktop.org/poppler/poppler |
| csvkit (`in2csv`) | konverze tabulek (XLSX/XLS) na CSV | MIT | https://github.com/wireservice/csvkit |
| ocrmypdf | OCR pipeline pro skenovaná PDF | MPL-2.0 | https://github.com/ocrmypdf/OCRmyPDF |
| tesseract | OCR engine | Apache-2.0 | https://github.com/tesseract-ocr/tesseract |
| **Ghostscript (`gs`)** | rasterizace PDF pro ocrmypdf | **AGPL-3.0** | https://www.ghostscript.com / https://git.ghostscript.com |
| Python (python-build-standalone) | runtime pro csvkit a ocrmypdf | PSF | https://github.com/astral-sh/python-build-standalone |

## Ghostscript — AGPL-3.0

Ghostscript je licencován pod **GNU Affero General Public License v3.0**. Pokud
aplikaci distribuuješ s bundlovaným `gs` (viz [bundle_ocr_tools.sh](../scripts/bundle_ocr_tools.sh)):

- přilož plný text licence AGPL-3.0 (https://www.gnu.org/licenses/agpl-3.0.html),
- zpřístup odpovídající zdrojový kód Ghostscriptu, případně písemnou nabídku
  jeho poskytnutí (`gs` je dostupný na https://git.ghostscript.com),
- uveď tuto skutečnost v licenčních podmínkách / acknowledgements aplikace
  (v aplikaci: **Předvolby → OCR → Licence třetích stran**).

Pokud bundlovaný Ghostscript není žádoucí (kvůli AGPL), lze ho z balíčku vynechat
— ocrmypdf bez `gs` neproběhne a aplikace spadne zpět na Apple Vision OCR.

## In-app

Tytéž informace jsou dostupné v aplikaci v **Předvolby → OCR → Licence třetích
stran**. Při změně bundlovaných nástrojů aktualizuj zároveň tabulku zde i sekci
v [SettingsView.swift](../SpiceHarvester/Views/SettingsView.swift).
