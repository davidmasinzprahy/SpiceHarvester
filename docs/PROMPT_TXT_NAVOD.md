# Práce s prompty

Aplikace používá **jeden aktivní prompt** (`currentPrompt`) pro aktuální běh extrakce.
Prompt můžeš psát ručně v editoru nebo načíst z libovolného `.md` souboru.

## Doporučený workflow

1. Vytvoř složku, kde budeš ukládat prompty (např. `Prompty/`).
2. Ulož do ní `.md` soubory s variantami promptu — jméno souboru = jméno v pickeru.
3. V UI nastav **Prompty (.md)** složku přes **Vybrat**.
4. Klikni **Načíst ze složky** — appka naplní picker seznamem `.md` souborů.
5. Vyber soubor → obsah se vloží do editoru.
6. Prompt můžeš dál ručně upravit. Každá editace se debounced persistuje, neboj se.
7. Klikni **Vymazat** pro reset editoru zpět na placeholder.

Změny se ukládají 300 ms po posledním keystroku. Při ukončení aplikace se pending změny bezpečně flushnou.

## Jak aplikace prompt používá

- Aktivní prompt se posílá do `SHExtractionPipeline` jako `SHPromptTemplate` (jeden prompt, jedna úloha).
- System prompt je **minimální** a neobsahuje žádné schéma: *"Jsi extrakční engine. Odpovídej výhradně validním JSON podle schématu ze zadání. Nevracej markdown ani vysvětlení, pouze samotný JSON."*
- **Schéma výstupu plně určuje tvůj prompt.** Pipeline nevkládá vlastní schéma do requestu.
- V **FAST** / **SEARCH** režimu: prompt se použije per dokument (každé PDF samostatný request).
- V **CONSOLIDATE** režimu: prompt se použije jednou nad sloučeným batchem (`Dokument #1: name.pdf ===`, `Dokument #2: …`).

## Zpracování odpovědi

1. Raw LLM odpověď se vždycky uloží do `rawResponse` (pole v `SHExtractionResult`).
2. Pipeline se **pokusí** dekódovat proti internímu kanonickému schématu (medicínské atributy: `patient_name`, `diagnoses`, …).
3. **Když neprojde → bez repair retry**, raw odpověď je finální výstup (dostane se do exportu jako `{name}_raw.json` nebo `{name}_raw.txt`).

Dřívější "repair retry" flow byl odstraněn, protože pro custom schémata produkoval falešné kanonické záznamy a plýtval inferencí.

## Kanonické schéma (volitelné)

Když napíšeš prompt **přesně pro toto schéma**, výstup se automaticky rozprostře do strukturovaného JSON/CSV/TXT:

```json
{
  "source_file": "",
  "patient_name": "",
  "patient_id": "",
  "birth_date": "",
  "admission_date": "",
  "discharge_date": "",
  "diagnoses": [],
  "medication": [],
  "lab_values": [],
  "discharge_status": "",
  "warnings": [],
  "confidence": 0.0
}
```

Pokud se trefíš, `results.csv` bude mít validní sloupce, `results.txt` bude čitelný sumář atd. Jinak (jakékoli vlastní schéma) = vše v `rawResponse` + export do `{name}_raw.*`.

## Speciální konvence: CSV + TXT markery

Pokud chceš **tabulkový výstup přímo pro Excel + lidsky čitelný sumář současně**, napiš prompt s oddělovací konvencí:

```
Výsledkem musí být přesně dvě sekce oddělené markery:

=====CSV=====
(tabulka CSV s hlavičkou; čárka oddělovač, string s čárkou v uvozovkách, desetinná tečka)
=====TXT=====
(lidsky čitelný souhrn; jeden blok na záznam, prázdný řádek mezi bloky)

Výstup začíná přesně textem "=====CSV=====" na prvním řádku.
NEPOUŽÍVEJ markdown ani ``` code-fence.
```

Pipeline automaticky rozpozná markery a uloží:
- `{name}_raw.csv` — čistý CSV s UTF-8 BOM pro Excel na macOS
- `{name}_raw.txt` — čistý TXT sumář

Detekce je přes `SHExportService.parseCSVTXTSections`: musí obsahovat oba markery v pořadí CSV → TXT a mezi nimi non-empty obsah. Fallback: pokud markery chybí nebo jsou špatně pořadí, rawResponse se uloží normálně jako JSON nebo TXT.

## Tipy pro psaní promptu

- Piš **explicitně**: „Vrať pouze validní JSON / CSV, bez markdown fence."
- Uveď přesné klíče a datové typy.
- Definuj formát dat (`YYYY-MM-DD`), když je potřeba.
- Pro CSV: specifikuj oddělovač, desetinný oddělovač (tečka vs čárka), escape pravidla pro čárku/uvozovky/newline.
- Uveď, co dělat při chybějících údajích (prázdná buňka, `null`, „není známo").
- Drž prompt krátký a deterministický — čím stručnější, tím rychlejší inference a méně tokenů.
- **CONSOLIDATE**: explicitně řekni *"Zpracuj celý vstup jako jeden datový celek, neopakuj odpověď per dokument"* — jinak model může vracet array s jedním objektem per dokument.

## Detekce nesouladu promptu a režimu

Appka analyzuje prompt a **upozorní žlutým bannerem**, pokud si nesedí s vybraným režimem. Detekuje klíčová slova:

| Klíčová slova v promptu | Doporučený režim |
|---|---|
| *"celý vstup jako jeden"*, *"napříč dokumenty"*, *"jediný JSON array"*, *"konsoliduj"*, *"aggregate"*, *"consolidate"* | CONSOLIDATE |
| *"pro každý soubor"*, *"per file"*, *"per document"* | FAST |
| *"semantic"*, *"retrieval"*, *"rag"*, *"najdi relevantní pasáže"* | SEARCH |

Jeden klik v banneru přepne režim. Při prvním matchi vítězí kategorie s nejvyšší prioritou (CONSOLIDATE → FAST → SEARCH).

## Rychlé iterace

Po **změně promptu** obvykle **není nutné opakovat předzpracování** — cache PDF souborů je fileHash-based, nezávisí na promptu.

Ale nová inference proběhne, protože prompt je součást inference cache klíče. Výjimka: když zaškrtneš **Ignorovat cache LLM odpovědí**, vynucuje se nový LLM call i při identickém promptu (užitečné pro non-deterministické modely).

**Cache hit flow při iteraci:**
1. Spustíš `Spustit` s promptem A → předzpracování (~1 min) + inference (~10 min).
2. Upravíš prompt na B → předzpracování **skip** (docs z cache), inference `miss` pro B (~10 min).
3. Vrátíš se k promptu A → předzpracování skip, inference **hit** → instant.

Statusbar ukáže *"12× cache hit"* pokud bylo 12 dokumentů z cache (FAST/SEARCH) nebo *"1× cache hit"* v CONSOLIDATE.

## Map-reduce v CONSOLIDATE

Pokud CONSOLIDATE batch přetéká kontext modelu, pipeline automaticky použije **map-reduce**:

1. **MAP**: dokumenty se rozdělí do K dávek. Každá dávka → LLM request s wrapper promptem *"Toto je dávka #N z K. Zpracuj jen přiložené dokumenty…"* + tvůj originální prompt + dokumenty dávky. Výstup je dílčí odpověď ve tvém formátu.
2. **REDUCE**: všechny MAP výstupy + tvůj originální prompt se pošlou v posledním LM volání s instrukcí *"Spoj dílčí výstupy do jediného, dedupli­kuj záznamy…"*.

**Per-fáze cache**: každá dávka má vlastní cache klíč (`modeTag: consolidate-map`), reduce taky (`modeTag: consolidate-reduce`). Výhody:
- Iterace na promptu: cache hits pro MAP dávky, které se nezměnily; miss jen tam, kde to dává smysl.
- Cancel/restart uprostřed běhu: dokončené MAP dávky jsou v cache → při dalším spuštění instant.
- Změna počtu dokumentů = nový reduce klíč (obsahuje `batches=N`), ale existující MAP dávky zůstávají valid.

**Co to znamená pro psaní promptu**:
- Tvůj prompt musí fungovat i pro **menší podmnožinu dokumentů** (1–10 místo 100). Wrapper v MAP fázi to komunikuje, ale prompt by neměl tvrdě spoléhat na absolutní počty.
- Při psaní instrukcí typu *"pokud stejný pacient, sluč údaje"* si uvědom, že MAP to dělá **uvnitř dávky**, REDUCE **napříč dávkami**. Obojí běží přes tvůj prompt — stejná pravidla tedy platí v obou fázích.
- Tvůj prompt je **jediná autorita** nad formátem. Ani REDUCE nedoplňuje žádné metainformace, pouze konsolidovaný výstup ve tvém formátu.

Pokud chceš map-reduce vynutit i pro malý batch (testování), můžeš ručně snížit **Kontext modelu** ve stepperu — když je budget < vstup, map-reduce se aktivuje.
