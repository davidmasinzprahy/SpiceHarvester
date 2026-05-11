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
| Karta serveru | **Server** | — | Po split na 2 karty (dříve „Server a model"). Hostuje pouze server registry + connection details. |
| Karta modelů | **Modely a režim** | — | 4 model pickery (Embedding/Reranker hidden v non-SEARCH) + segmented Režim. |
| Onboarding strip | **Začni tady** | — | Klikatelné chips, fokus skočí na první actionable kontrolu sekce. |
| Multi-window primary | **hlavní okno** / **primary** | `WindowGroup(id: "main")` | UserDefaults persistence on. |
| Multi-window secondary | **scratch okno** / **nové okno** | `WindowGroup(id: "scratch", for: UUID.self)` | UserDefaults persistence off; per-session. |
| Save/Load Project | **Otevřít projekt…** / **Uložit projekt jako…** | `openProject`, `saveProjectAs` | `.spiceharvester.json` JSON snapshot. Cmd+O / Cmd+Shift+S. |
| Project file | **projekt** | `SHProjectSnapshot` | Codable struct s folder + model + prompt + mode. Server registry NOT included (globální). |
| Naposledy použité složky | **Naposledy** (submenu) | `recentFolders[SHFolderKind]` | Per-kind 5 entries v UserDefaults. |
| Prompt history | **Historie** (Menu) | `promptHistory` | 8 nejnovějších prompts ze Spustit. |
| Notification akce | **Otevřít výstup** | `OPEN_OUTPUT` (UNNotificationAction) | Klik na akci na Notification Center banneru. |
| Server health | **Server odpojen** (status pill červená) | `isVerifiedServerReachable` | Detekováno 30 s ambient ping loop. |
| Sub-second průměr | **ø X ms** | `humanDurationDetailed` | Pro cache-only baselines pod 1 s. |
| Live throughput | **N dok/min · ⌀ T s/dok** | — | V Progress kartě vedle ETA při běhu. |
| Drag handle | drobná pila uprostřed VSplitView dělítka | `dragHandleGrip` | Vizuální affordance "tažitelný separator". |
| Tab cyklus | **Tab** / **Shift+Tab** mezi aktivními tlačítky | NSEvent monitor + `@FocusState` | Vlastní implementace, nezávislá na sys Keyboard Navigation. |
| Pipeline menu | **Pipeline** (top-level v menu baru) | `CommandMenu("Pipeline")` | Sjednocené pro Spustit/Přerušit/Předzpracování/Extrakce/Režim/server recheck. Vzor: Xcode Product, Logic Track. |
| Recent projects | **Otevřít nedávné** (File submenu) | `recentProjectURLs` | Max 8 položek, persistované v UserDefaults; dead path se auto-odebere. |
| Manual server ping | **Znovu ověřit zdraví serveru** | `recheckServerNow()` | Mimo 30 s health watcher loop; pro okamžitou kontrolu po restartu LM Studia. |
| Akce v Zkratky.app | **Spustit extrakci** / **Otevřít výstupní složku** | `RunSpiceHarvesterIntent`, `OpenOutputFolderIntent` | UI label v aplikaci Zkratky. Anglicky: `Run Spice Harvester`. |
| Job / plánovaný běh | **job** (uživatelská dokumentace), v helpu **plánovaný běh** | — | Synonyma. Vždy myšleno spuštění přes Zkratky / Automation, ne cron na úrovni OS. |
| Parametr akce | **parametr** | `@Parameter` | UI label v editoru Zkratky: **Režim** / **Název promptu**. |
| Návratová hodnota akce | **výstup akce** (UI Zkratek) / **cesta k results.csv** | `ReturnsValue<String>` | Co dostane další krok ve Zkratce. |
| Cílová záložka | **cílová záložka** (parametr) | `targetFolder` parameter | V helpu: „název vstupní složky té záložky, kde má pipeline běžet". |
| Titulek záložky / okna | **titulek záložky** | `windowTitle` (computed) | Co macOS renderuje v title baru a v tab labelu po sloučení oken. Formát: `Spice Harvester — <input> [· scratch]`. |
| Podtitulek záložky | **podtitulek** | `windowSubtitle` (computed) | Pod titulkem (macOS title bar). Server · režim · progres/dokončení. |
| Kolize výstupní složky | **výstupní složka je zaneprázdněná jinou záložkou** | `activeOutputClaims` | Status text při blokovaném spuštění. |
| Help okno | **Nápověda Spice Harvester** | `Window(id: "help")` | Samostatné okno, ne sheet. Singleton — druhé Cmd+? fokusne existující. |

## Kontrola konzistence

Před commitem grep nad `SpiceHarvester/`:

```bash
grep -rn "Preprocessing\|preprocessing" --include="*.swift" SpiceHarvester/
grep -rn "request\|Request" --include="*.swift" SpiceHarvester/Views/ SpiceHarvester/ContentView.swift
grep -rn "Detailní log\|Spustit vše\|Zrušeno" --include="*.swift" SpiceHarvester/
```

Žádný z výrazů na pravé straně tabulky výše by se neměl objevit v uživatelsky viditelném textu mimo komentáře a identifikátory v kódu.
