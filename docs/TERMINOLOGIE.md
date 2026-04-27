# Terminologický slovník

Jediný zdroj pravdy pro pojmenování v GUI, nápovědě (HelpSheet) a uživatelské dokumentaci. Při přidávání nových textů použij kanonický termín z tohoto souboru. Pokud zavádíš nový pojem, nejdřív ho doplň sem.

## Zásady

1. **UI a uživatelská dokumentace = čeština.** Anglické termíny ponecháváme jen tam, kde jsou v oboru standardem (názvy režimů `FAST` / `SEARCH` / `CONSOLIDATE`, `cache`, `RAG`, `OCR`, `prompt`, `LM Studio`, `MLX`, `JSON` / `CSV`).
2. **Kód (typy, metody, properties) = angličtina.** Interní názvy (`SHPreprocessingPipeline`, `runPreprocessing`, `inputFolder`) zůstávají, jen v UI textech a komentářích vázaných na UI použij český kanonický pojem.
3. **Mezi technickou variantou a uživatelskou variantou volí podle čtenáře.** Status bar a tooltip = krátké („Vstup", „Výstup"), help a chybové hlášky = explicitní („vstupní složka", „výstupní složka").

## Slovník

| Koncept | Kanonický termín v UI/helpu/dokumentaci | Technický termín v kódu | Poznámka |
|---|---|---|---|
| Fáze 1 — extrakce textu z PDF + OCR | **Předzpracování** | `preprocessing`, `SHPreprocessingPipeline` | Synonymum „preprocessing" se v UI nepoužívá. V helpu lze za první výskyt přidat upřesnění „(OCR + extrakce textu)". |
| Fáze 2 — AI inference nad texty | **Extrakce** | `extraction`, `SHExtractionPipeline` | „AI inference" je technický doplněk, jen v helpu jako podtitulek. |
| Spuštění kompletního běhu | **Spustit** | `runAll`, `run` | Bez „vše" — tlačítko vždy spouští obě fáze. Klávesová zkratka Cmd+R. |
| Přerušení běžícího běhu | **Přerušit** | `cancelRun`, `cancel` | Cmd+. Stejné slovo používá toolbar i menu. |
| Volba režimu extrakce | **Režim extrakce** | `extractionMode`, `SHExtractionMode` | Label nad pickerem i jméno karty. |
| Hodnoty režimu | **FAST**, **SEARCH**, **CONSOLIDATE** | `.fast`, `.search`, `.consolidate` | V angličtině, drží se konvence z IR/ML. |
| Vstupní složka | UI label: **Vstup**. V helpu/chybách: **vstupní složka**. | `inputFolder` | |
| Výstupní složka | UI label: **Výstup**. V helpu/chybách: **výstupní složka**. Tlačítko v toolbaru: **Otevřít výstup**. | `outputFolder` | |
| Cache | **Cache** | `cache`, `SHCacheManager`, `SHInferenceCache` | Nikdy „mezipaměť". |
| Cache pro AI odpovědi | **cache LLM odpovědí** (toggle), v helpu **inferenční cache** | `inferenceCache` | |
| Prompt | **Prompt** (UI), v helpu lze upřesnit „pokyn pro AI" | `prompt`, `currentPrompt` | |
| AI server | **Server** (UI label). V helpu **lokální AI server**. Detail: **Base URL**. | `server`, `SHLMStudioServer` | |
| Model — typy | **Inference**, **Embedding**, **Reranker**, **OCR/VLM** | `selectedInferenceModel`, `selectedEmbeddingModel`, `selectedRerankerModel`, `selectedOCRModel` | Picker labely v `Server a model`. |
| Ověření serveru | Tlačítko: **Ověřit** / po úspěchu **Ověřeno**. Status: **Ověření selhalo**. | `verifyServer`, `isSelectedServerVerified` | |
| Stav průběhu (běh) | **Inicializace** / **Probíhá** / **Bez pokroku** / **Pozastaveno** | `SHProgressHealth` | |
| Fáze v progress kartě | **Předzpracování (OCR + extrakce textu)** / **Extrakce (AI inference)** / **Připraveno** / **Dokončeno** | `phaseTitle` | |
| Výsledek běhu (banner + finished card) | **Hotovo** / **Přerušeno** / **Selhalo** | `SHRunCompletion.success/cancelled/failed` | Stejné termíny v banneru i v progress kartě po dokončení. |
| Karta logu | **Log** | — | Ne „Detailní log" (pleonasmus). |
| Požadavek na server | **požadavek** | `request` | V UI/helpu i tooltipech vždy česky. |

## Kontrola konzistence

Před commitem grep nad `SpiceHarvester/`:

```bash
grep -rn "Preprocessing\|preprocessing" --include="*.swift" SpiceHarvester/
grep -rn "request\|Request" --include="*.swift" SpiceHarvester/Views/ SpiceHarvester/ContentView.swift
grep -rn "Detailní log\|Spustit vše\|Zrušeno" --include="*.swift" SpiceHarvester/
```

Žádný z výrazů na pravé straně tabulky výše by se neměl objevit v uživatelsky viditelném textu mimo komentáře a identifikátory v kódu.
