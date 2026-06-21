# Uživatelská nápověda

Tento návod odpovídá aktuálnímu UI aplikace Spice Harvester.

## Layout aplikace

Hlavní okno je dvousloupcové:
- **Vlevo (konfigurace + ovládání):**
  - Onboarding strip (zmizí po dokončení 4 kroků)
  - Složky · Server · Modely a režim
  - Dělící čára
  - Status pill + **Spustit / Výstup / Nápověda**
- **Vpravo (workspace):**
  - Notifikační bannery (completion + konflikty)
  - **VSplitView** s tažitelnými dělítky: Prompt → Průběh → Log

Rozdělovač mezi sloupci lze tahat. Mezi Prompt / Průběh / Log jsou tažitelná dělítka VSplitView (drobné šedé pily uprostřed dělítka). Dole je **status bar** s textovým runtime stavem; **auto-collapse** když je text default „Připraveno".

Pokročilá nastavení (souběžnost, throttle, kontext modelu, timeout, OCR backend, cache) jsou v **Předvolbách** (`Cmd+,`) — fulltextové vyhledávání nahoře.

## Multi-window

- **Cmd+Shift+N** otevře *scratch* okno s vlastní prázdnou konfigurací
- Scratch okno **nepersistuje** do UserDefaults (server registry sdílen, ostatní per-session)
- Pro persistování: **Uložit projekt jako…** (Cmd+Shift+S) → `.spiceharvester.json`

### Identifikace záložky v titulku okna

Když si macOS sloučí okna do tabů (Window → Sloučit všechna okna), každý tab/okno ukazuje svůj kontext, takže nevidíš čtyři stejné „SpiceHarvester":

- **Titulek**: `Spice Harvester — <jméno vstupní složky>` (např. `Spice Harvester — EmbolieTesty`); ze scratch okna doplněno `· scratch`
- **Podtitulek**: `<server> · <režim> · <progres>` (např. `Local LM Studio · FAST · 5 / 16`). Při klidovém stavu jen server. Po dokončení `Hotovo · N dokumentů`

Pokud chceš různé tabs spouštět **paralelně proti různým LM Studio instancím**, přidej víc serverů (různé Base URL) v sekci Server a v každé záložce vyber jiný. Server v titulku ti potvrdí kombinaci.

### Detekce kolize výstupní složky

Pokud máš ve dvou tabech stejnou **výstupní složku** a v jedné spustíš pipeline, druhý tab tlačítko Spustit zakáže — proběh by jinak přepsal `results.csv` prvního. Status text v druhém tabu ukáže: *„Výstupní složka je zaneprázdněná jinou záložkou (Spice Harvester — XY) — počkej, nebo zvol jinou."*

Cleanup je automatický — když první běh skončí (success/cancel/fail), druhý tab se odblokuje.

### Nápověda jako samostatné okno

`Cmd+?` (nebo tlačítko Nápověda) otevře **samostatné okno** s nápovědou — ne sheet. V tabbed-window scénáři by sheet jinak „přesakoval" do všech tabů. Druhé Cmd+? jen fokusne existující okno (singleton).

## Save / Open Project

- **Cmd+Shift+S** — uloží snapshot folderů, modelů, promptu a režimu do `.spiceharvester.json`
- **Cmd+O** — načte projekt zpět; sandbox bookmarky **nelze obejít**, takže pokud cesty z projektu nebyly v této instalaci dosud vybrány, aplikace upozorní alertem a uživatel musí re-pick
- **Finder** — `.spiceharvester.json` lze otevřít i **dvojklikem** nebo **přetažením na ikonu** aplikace (projekt se načte do hlavního okna; během běhu úlohy se otevření odmítne)
- **Server registry** se neukládá do projektu (servery jsou globální per-installation)

## Klávesové zkratky

### Pipeline
| Akce | Zkratka |
|---|---|
| Spustit | **Cmd+R** |
| Přerušit | **Cmd+.** |
| Předzpracování | **Cmd+Shift+P** |
| Extrakce | **Cmd+Shift+E** |
| Režim **FAST** | **Cmd+1** |
| Režim **SEARCH** | **Cmd+2** |
| Režim **CONSOLIDATE** | **Cmd+3** |

### Soubory a okna
| Akce | Zkratka |
|---|---|
| Otevřít projekt… | **Cmd+O** |
| Uložit projekt jako… | **Cmd+Shift+S** |
| Nové okno (scratch) | **Cmd+Shift+N** |
| Otevřít výstup ve Finderu | **Cmd+Shift+O** |
| Otevřít výsledek… | **Cmd+Shift+R** |

### Editor a navigace
| Akce | Zkratka |
|---|---|
| Zpět (po Vymazat prompt) | **Cmd+Z** |
| Fokus filtru logu | **Cmd+F** |
| Tab / Shift+Tab | cyklus mezi aktivními tlačítky |
| Esc | uvolnit textový vstup, fokus skočí na Spustit |

### App
| Akce | Zkratka |
|---|---|
| Předvolby | **Cmd+,** |
| Nápověda | **Cmd+?** |

> Tab/Shift+Tab cyklus funguje **i bez** systémového *Keyboard Navigation* (System Settings → Keyboard) — aplikace má vlastní `NSEvent` monitor a respektuje stejné `canX` predikáty jako disabled state tlačítek.

## Menu bar layout

Aplikace přidává custom top-level menu **Pipeline** mezi standardní macOS menu — pipeline akce (Spustit, Přerušit, Předzpracování, Extrakce, Režim, Znovu ověřit server) jsou tam sjednocené. **File** menu drží jen project/document operace.

### File
- **Nové okno (scratch)** — Cmd+Shift+N
- **Otevřít projekt…** — Cmd+O
- **Otevřít nedávné** › last 8 projektů + Vyčistit seznam
- **Uložit projekt jako…** — Cmd+Shift+S
- **Otevřít výsledek…** — Cmd+Shift+R (načte `.spice-result.json` exportovaný přes Export → JSON; pipeline tlačítka jsou během zobrazení výsledku disabled)
- **Otevřít výstup ve Finderu** — Cmd+Shift+O

### Pipeline *(custom)*
- **Spustit** / **Přerušit** — Cmd+R / Cmd+.
- **Předzpracování** — Cmd+Shift+P
- **Extrakce** — Cmd+Shift+E
- **Režim FAST / SEARCH / CONSOLIDATE** — Cmd+1 / Cmd+2 / Cmd+3
- **Znovu ověřit zdraví serveru** — manuální ping mimo 30 s health watcher (užitečné hned po restartu LM Studia: kliknutí dá okamžitou červenou/zelenou indikaci místo čekání až 30 s na další scheduled ping)

### Otevřít nedávné

Po každém **Uložit projekt jako…** nebo **Otevřít projekt…** se cesta zaznamenává do persistentního seznamu (max 8). V submenu se zobrazují jako `název · cesta` (s tildeify, např. `medical · ~/Documents/projects`). Kliknutí přímo načte projekt — bez panel dialogu. Když cesta selže (soubor smazán), automaticky se ze seznamu odebere.

## Shortcuts.app + Siri (spouštění jako job)

V macOS Zkratky.app jsou registrované akce:

- **Spustit extrakci (Spice Harvester)** — spustí kompletní pipeline (Předzpracování + Extrakce). Akce **čeká na dokončení** a vrátí cestu k výslednému CSV — další krok ve Zkratce poběží teprve potom.
- **Otevřít výstupní složku (Spice Harvester)** — otevře výstupní složku ve Finderu.

Hlasem (Siri / Spotlight, macOS 14+): *„Spusť Spice Harvester"*, *„Run Spice Harvester"*, *„Otevři výstup Spice Harvester"*.

### Volitelné parametry akce „Spustit extrakci"

| Parametr | Co dělá | Pokud zůstane prázdné |
|---|---|---|
| **Režim** | Picker FAST / SEARCH / CONSOLIDATE — přepíše režim extrakce jen pro tento běh | Použije se režim aktuálně zvolený v cílové záložce |
| **Název promptu** | Filename z prompt složky (např. `lekarska-zprava.md`) — načte se před spuštěním. Tolerantní k velikosti písmen a `.md` suffix lze vynechat | Použije se prompt načtený v editoru |
| **Cílová záložka (vstupní složka)** | Název vstupní složky té záložky, ve které se má extrakce spustit (např. `EmbolieTesty`). Match je case-insensitive | Spustí se v hlavní záložce (primary window) |

Vstupní/výstupní/cache/prompt složka, server a model se **vždy** berou z uložené konfigurace cílové záložky. (Důvod: macOS sandbox vyžaduje, aby cesty měly platný security-scoped bookmark; ten vzniká jedině když je uživatel vybere přes picker v aplikaci. Předání cesty parametrem v Zkratkách by sandbox stejně odmítl.)

**Cílení na konkrétní záložku** umožní paralelně spravovat víc workflow v jedné app — např. jeden plánovaný job v 8:00 pro `EmbolieTesty`, druhý v 9:00 pro `Pacient2025`. Pokud žádná otevřená záložka název vstupní složky nemá, akce vrátí `notStarted · Žádná otevřená záložka nemá vstupní složku: <název>`.

Při spuštění akce přivolá aplikace cílovou záložku do popředí (makeKeyAndOrderFront), takže v tabbed-window groupách hned vidíš, kde běh probíhá.

**Override teď neměnní permanentně app config:** snapshot/restore — po skončení běhu se režim/prompt v UI vrátí na hodnoty před spuštěním Shortcutu. Plánované joby s `mode: SEARCH` nepřepíšou tvůj denní FAST setup.

### Návratová hodnota

Akce vrací **cestu k `results.csv`** v uložené výstupní složce. Dá se zřetězit:

- *Připojit k mailu* → odešle CSV jako přílohu (denní reporting)
- *Run Shell Script* → např. `git -C /repo commit -am "daily" && git push`
- *Get File Contents* → vlož do tabulky / databáze
- *Make Speak Text* → Siri přečte počet zpracovaných dokumentů

Když pipeline selže nebo nevznikne CSV, akce vrátí krátký status string (např. `failed · 0` nebo `cancelled · 12`) a do dialogu zapíše čitelný popis.

### Plánovaný job (cron-like)

1. **Zkratky.app** → záložka **Automatizace** → ➕.
2. Trigger: **Time of Day** (např. denně v 8:00) nebo **When I Open / Close an App**.
3. Akce: **Spustit extrakci** + libovolně další kroky (mail, Slack, push do gitu…).
4. Vypni **Ask Before Running** pro skutečně tichý běh.

> ⚠️ **Než plánovaný job poprvé pustíš**, otevři aplikaci ručně a:
> - Vyber všechny složky (Vstup / Výstup / Cache / Prompty) přes picker — sandbox si uloží bookmarky, které job potřebuje.
> - Ověř server (klik na **Ověřit**).
> - Pokud chceš v plánu zafixovaný režim/prompt, vyplň ho do parametrů akce; jinak job bude vždy brát to, co je v aplikaci aktuálně.

Aplikace se při spuštění jobu probudí na popředí (`openAppWhenRun: true`). Můžeš ji minimalizovat nebo dát do druhého desktopu — pipeline poběží bez ohledu na fokus.

## Rychlý start

1. Spusť **LM Studio** nebo **MLX OpenAI-compatible server** a načti model (doporučeně s co největším kontextem, který ti RAM dovolí).
2. V levém sloupci, sekce **Složky** — nastav cesty:
   - `Vstup` — kde jsou PDF
   - `Výstup` — kam se zapíšou výsledky
   - `Cache` — kde bude JSON cache (může být kdekoli, klidně v projektové složce)
   - `Prompty (.md)` — složka s .md soubory obsahujícími prompty *(volitelné)*. Soubory se hledají **rekurzivně včetně podsložek** (SHPromptLibraryService používá `FileManager.enumerator`).

   > **Tip 1:** cestu lze nastavit **přetažením složky z Finderu** přímo do políčka cesty. Tlačítko „Vybrat" / „Změnit" otevře klasický picker. Přetažená složka si zároveň uloží security-scoped bookmark (stejně jako při výběru přes picker), takže zůstane čitelná i přes sandbox napříč session.
   >
   > **Tip 2:** po prvním výběru se další picker otevře v nadřazené složce tvého výběru. Sourozenecké složky projektu jsou tak na jeden klik.

3. V sekci **Server**:
   - vyber nebo přidej server (výchozí je `http://localhost:1234/v1` pro LM Studio; MLX preset používá `http://localhost:8000/v1`)
   - **Inline validace URL**: pokud je Base URL malformed (chybí `http://`, hostitel atd.), vedle pole se objeví ⚠️ ikona — **Ověřit** by stejně selhal po HTTP timeoutu, ale tady to vidíš okamžitě
   - klikni **Ověřit** — tlačítko zezelená na **Ověřeno**, statusbar ukáže počet modelů a u LM Studia také auto-detekovaný kontext
   - **Health watcher** — po Ověřit aplikace každých 30 s pinguje server. Když přestane odpovídat, status pill se přebarví červeně na **„Server odpojen"** — uvidíš to ještě než klikneš Spustit
4. V sekci **Modely a režim**:
   - vyber **Inference** model + případně **OCR/VLM** model
   - **Embedding** + **Reranker** pickery se zobrazí jen v režimu **SEARCH** (jinak by byly visual noise)
   - vyber **Režim extrakce** — **Cmd+1** / **Cmd+2** / **Cmd+3** přepínají FAST / SEARCH / CONSOLIDATE bez kliknutí myší
5. V sekci **Prompt**:
   - napiš prompt přímo do editoru, nebo
   - klikni **Načíst** a vyber `.md` v pickeru — obsah se vloží do editoru
   - **Historie** menu vedle Načíst nabízí 8 naposledy spuštěných promptů (z úspěšných runů)
   - **Fullscreen toggle** (`↗` ikona vpravo) — Prompt zabere celý pravý sloupec; auto-collapse při startu runu
6. Stiskni **Spustit** (nebo `Cmd+R`).

## Barvy a co znamenají

- **Zelená** — něco je **ověřené / aktivní / dokončené** (ověřený server, vybraná složka, dokončený run)
- **Modrá** — **akce je spustitelná** (všechny prerekvizity splněny)
- **Šedá (disabled)** — **chybí prerekvizita** (např. `Extrakce` je šedá, dokud nezadáš prompt)
- **Červená** — **destruktivní nebo kritická akce** (Přerušit, Selhalo)
- **Primary** (černá/bílá dle módu) — dekorace, neutralní indikátory

## Co dělají tlačítka

### Run row (spodek levého sloupce)
- **Status pill (vlevo)** — call-to-action: „Zadej cesty ke složkám", „Můžeš spustit", „Server odpojen" (červeně po health-watcher detekci). Při běhu spinner + „Zpracovávám…".
- **Spustit / Přerušit (Cmd+R / Cmd+.)** — jeden slot. **Spustit** je `.borderedProminent` modré (primary CTA), **Přerušit** je `.bordered` červené (destructive). Při běhu se přepne automaticky.
- **Výstup (Cmd+Shift+O)** — otevře výstupní složku ve Finderu. Také je to **drag source**: přetáhni tlačítko na Finder / Slack / Mail = output folder se předá jako file representation.
- **Nápověda (Cmd+?)** — otevře samostatné okno nápovědy.
- **Adaptive labels**: když je okno úzké (~< 940 pt), tlačítka se zobrazí jen jako ikony (tooltipy zachovány).

### Konfigurační sloupec
- **Vybrat / Změnit (folder row)** — otevře `NSOpenPanel`. Po prvním picknutí se z buttonu stane **Menu** s submenu „Naposledy" obsahující 5 nejnovějších cest pro tento slot (per-kind: Vstup / Výstup / Cache / Prompty). Cestu lze také přetáhnout z Finderu.
- **PDF chip pod Vstup row** — po vybrání vstupní složky aplikace zobrazí počet PDF + celkovou velikost (`23 PDF · 142 MB`). Oranžový chip „Žádné PDF" pokud složka neobsahuje žádné PDF. Async scan, neblokuje main thread.
- **+ / − server** — přidá / odebere registry položku. Vedle je preset **MLX** (přidá `http://localhost:8000/v1`).
- **Ověřit / Ověřeno (server)** — otestuje lokální OpenAI-compatible server (`/v1/models`), načte seznam modelů a u LM Studia navíc přes `/api/v0/models` auto-nastaví **Kontext modelu** ze skutečné hodnoty `loaded_context_length`. U MLX/obecných backendů status bar ukáže `kontext ručně` a hodnotu nastavíš v **Předvolbách → Výkon**. Po přepnutí mezi LM Studio/MLX aplikace vyčistí předchozí model selections; po ověření zkontroluj **Inference** i **Embedding** picker proti nově načtenému seznamu. Při úspěchu zůstává **zelené "Ověřeno"** dokud nezměníš URL / API key / vybraný server. Po Ověřit se aktivuje **30 s health watcher** (viz výše).
- **Načíst (prompt)** — oskenuje prompt folder, naplní picker souborů (`.md`).
- **Historie (prompt)** — Menu se 8 naposledy spuštěnými prompty (zaznamenané automaticky při Spustit).
- **nothink / think** — vloží do promptu instrukci `/no_think` nebo `/think` pro modely, které tento režim podporují (Qwen3, DeepSeek-R1).
- **Fullscreen toggle (↗ ikona)** — Prompt zabere celý pravý sloupec; auto-collapse při Spustit.
- **Vymazat (prompt)** — `.bordered` červené, vyžaduje confirmation dialog. **Cmd+Z obnoví** (NSUndoManager). Cmd+Shift+Z znovu vymaže.

### Menu File (klávesové zkratky)
- **Spustit (Cmd+R)** — alias k toolbar buttonu.
- **Přerušit (Cmd+.)** — propaguje `CancellationError` do pipeline; běžící LLM požadavek se zruší.
- **Předzpracování (Cmd+Shift+P)** — spustí pouze FÁZI 1 (scan/hash/cache/PDF/OCR/clean).
- **Extrakce (Cmd+Shift+E)** — spustí pouze FÁZI 2 (LLM extrakce nad cache); automaticky doplní předzpracování, pokud ještě nejsou data.

### Runtime sloupec
- **Načtený výsledek (importovaný banner)** — po otevření `.spice-result.json` (Cmd+Shift+R nebo double-click z Finderu) se zobrazí banner s pacient info (jméno, ID, diagnózy, medication, confidence). Pipeline tlačítka jsou disabled; klik na **Zavřít** vrátí UI do normálního stavu.
- **Hotovo / Přerušeno / Selhalo (completion banner)** — po dokončení runu se objeví nahoře v pravém sloupci. Klik na **Potvrdit** banner skryje a vrátí UI do připraveného stavu. Po **úspěšném** runu je banner také **drag source** — přetáhni ho do Finderu / Slacku → output folder se předá. Mimo app pak app pošle **Notification Center banner** s tlačítkem „Otevřít výstup".
- **Předchozí běh** v idle Průběh — po dokončeném runu zobrazí `⌀ X s/dok · Vstup: N · Odhad: ≈ T` (před spuštěním dalšího runu).
- **Live throughput** v aktivní Průběh — `12,3 dok/min · ⌀ 4,8 s/dok` vedle ETA — užitečné pro detekci zpomalení (KV cache, swap).
- **Currently processing** — pod ETA: `Probíhá: doc1.pdf, doc2.pdf (+1)` + `Naposledy: doc3.pdf`.
- **Filtr logu (Cmd+F)** — case-insensitive substring filter, zobrazí jen řádky obsahující text. **Kopírovat** zkopíruje aktuálně viditelné řádky.
- **Severity coloring v logu** — `[ERROR]` red, `[WARNING]` orange, `[INFO]` muted. Pro rychlý sken dlouhého logu.
- **Obnovit (log)** — načte aktuální tail `processing.log` z disku. Užitečné při dlouhém runu, kdy chceš nahlédnout na živý log dřív, než skončí aktuální fáze.
- **Drag handles** ve VSplitView — drobné pily (32×3 pt) na spodní hraně Promptu a Průběhu signalizují tažitelný separator.

### Conflict bannery (rozpor mezi configem a promptem)
- **Žluté** (`Doporučený režim: …`) — analyzer detekoval z promptu jiný režim než vybraný; klik na akční tlačítko nabídne přepnutí (s confirm dialogem proti false-positivu).
- **Oranžové** (`SEARCH bez embedding modelu`) — RAG nebude fungovat; klik nabídne přepnutí na FAST.
- **Modré** (`CONSOLIDATE zpracuje batch společně`) — informativní; tlačítko **Skrýt** ukončí banner do konce session.
- Bannery jsou **debounced 400 ms** — neblikají při psaní v editoru.

### V Předvolbách (Cmd+,)
- **Vyčistit cache** (tab Cache, červené `role: .destructive`) — smaže **obě** cache (per-dokument + per-inference odpovědi).
- **Ignorovat cache LLM odpovědí** (toggle) — vynutí novou inferenci i u identického dotazu.

## Režimy

V picker **Režim extrakce**:
- **FAST** — jeden požadavek per dokument, plný `cleanedText`. Nejrychlejší per-dokument start.
- **SEARCH** — chunking + paralelní embeddings + semantický výběr top chunků. Pokud je vybraný **Reranker**, širší sada kandidátů se ještě přeuspořádá přes `/v1/rerank`. Pro dlouhé dokumenty s krátkým promptem.
- **CONSOLIDATE** — všechny dokumenty v jednom požadavku. Pro deduplikaci napříč batche.
  - **Auto map-reduce**: když se batch nevejde do kontextu, pipeline automaticky rozdělí dokumenty do K dávek, každou zpracuje zvlášť (MAP fáze), pak finální deduplikační volání (REDUCE). Běh trvá déle (K+1 LM volání), ale funguje i pro 100+ PDF.
  - **Auto-refresh kontextu**: před spuštěním velkého batche se přepíše hodnota `modelContextTokens` ze skutečného `loaded_context_length` v LM Studiu — užitečné pokud jsi mezitím v LM Studiu načetl model s jiným kontextem.

Vedle labelu je info-ikonka — hover ukáže popis aktuálního módu.

### Co se stane, když prompt nesedí s režimem?

**Parameter Conflict banner** (žlutý) pod editorem promptu tě upozorní:

> 💡 *Doporučený režim: CONSOLIDATE — Prompt obsahuje „celý vstup jako jeden" – vyžaduje zpracování všech dokumentů najednou. Aktuálně je nastaveno FAST, doporučen CONSOLIDATE.*
>
> **[Přepnout na CONSOLIDATE]**

Jedno kliknutí = přepnutí. Detekují se i tyto konflikty:
- SEARCH bez embedding modelu → banner s přepnutím na FAST
- CONSOLIDATE informační banner: *"ignoruje Inference workers a Throttle"*

## Předvolby (Cmd+,)

Otevři přes menu **Spice Harvester → Settings…** nebo zkratkou `Cmd+,`. Nahoře jsou tři ikonové taby; vybraný tab má zvýrazněnou ikonu a název.

### Tab Výkon
- **Souběžné inference požadavky** (1–16) — souběžných LLM požadavků (FAST / SEARCH).
- **Souběžné PDF/OCR workery** (1–16) — souběžných dokumentů ve fázi předzpracování.
- **Throttle mezi požadavky** (0–2000 ms) — pauza mezi inference požadavky.
- **Kontext modelu** (4k–1M tokens) — velikost kontextového okna; auto-detekuje se z LM Studia při **Ověřit server**, u MLX backendu ji nastav ručně; pro CONSOLIDATE pre-flight kontrolu.
- **Timeout požadavku** (60 s – 60 min) — max doba jednoho HTTP požadavku na lokální AI server.

### Tab OCR
- **OCR backend** — `Apple Vision` běží lokálně bez AI serveru; `oMLX/VLM` posílá skenované stránky vybranému OCR/VLM modelu; `Vision→VLM` použije VLM jako fallback pro stránky, kde Vision nevrátí použitelný text; `ocrmypdf` je lokální OCR přes tesseract (bez AI serveru), při nedostupnosti spadne na Apple Vision.
- **OCR ocrmypdf** — *Jazyky* tesseractu spojené znakem `+` (default `ces+slk+deu+pol+eng`; bundlovaná tessdata obsahují jen tyto jazyky). Pod polem se ukáže seznam **dostupných jazyků** zjištěných z tesseractu; když zadáš kód, který chybí, objeví se ⚠️ varování (ocrmypdf takový jazyk přeskočí a spadne na Apple Vision). Prázdné pole se po potvrzení vrátí na default. *Timeout* omezuje jeden běh ocrmypdf nad dokumentem. Platí pro backend `ocrmypdf`.
- **Licence třetích stran** — přehled licencí bundlovaných nástrojů (mj. Ghostscript pod AGPL-3.0); detail v `docs/LICENCE_TRETI_STRANY.md`.

### Tab Cache
- **Ignorovat cache LLM odpovědí** — zaškrtni pro vynucení nové inference i při identickém dotazu (užitečné pro non-deterministické modely).
- **Vyčistit cache** (červené tlačítko) — smaže **obě** cache (per-dokument + per-inference odpovědi).

Doporučení pro ladění výkonu:
1. Zvyšuj **Souběžné inference požadavky** postupně (2 → 3 → 4).
2. Sleduj kartu **Průběh** a stabilitu lokálního AI serveru.
3. Při přetížení zvyš **Throttle mezi požadavky**.
4. `CONSOLIDATE` ignoruje workery i throttle (jeden požadavek) — informační banner pod editorem promptu ti to připomene.

## Karta Průběh (pravý sloupec)

Jediná karta zobrazující stav běhu — sloučili jsme původní rozdělené Progress + Výkon, protože uživatele zajímá jen aktuální stav, ne syrové countery.

**Idle stav** (před runem):
> ⏸ *Připraveno – spusťte zpracování tlačítkem „Spustit" v horní liště (Cmd+R).*

**Aktivní fáze** (předzpracování nebo extrakce):
- Hlavička: ikona fáze + název („Předzpracování (OCR + extrakce textu)" / „Extrakce (AI inference)") + procentuální stav
- Modrý progress bar
- Řádek: počet `N/M dokumentů` · Uplynulo `T`
- Oddělovač
- Řádek: Zbývá `~ETA`
- **Health row** — automatická detekce zaseknutí (`stuckAfter: 30 s`):
  - 🔵 *„Inicializace – čekám na první dokument…"* (prvních 15 s)
  - 🟢 *„Vše v pořádku · poslední pokrok před X s"*
  - 🟠 *„Zdá se, že je zpracování pozastavené (X s bez pokroku)"* — zkontroluj LM Studio

**Dokončený stav**:
- Outcome ikona + popis (Hotovo / Přerušeno / Selhalo / Ukončeno)
- Summary: `N/M dokumentů · trvalo T` (nebo `N/M LM kroků` pro CONSOLIDATE map-reduce)

Baseline (`lastRunAvg*Ms`) se persistuje přes restart appky, takže ETA je k dispozici už po prvním úspěšném runu.

## Cache — jak to funguje

### Per-dokument cache
- Klíč: SHA-256 hash souboru PDF
- Hodnota: `SHCachedDocument` (rawText, cleanedText, pages, metadata)
- Účel: pokud se PDF nezměnilo, příště se přeskočí OCR / PDF parsing / text cleaning
- Při přejmenování souboru se aktualizuje `sourceFile` v cache (hash zůstává stejný)

### Per-inference cache (LLM odpovědi)
- Klíč: hash(prompt + docs + model + cleaner verze + mode)
- Hodnota: raw LLM odpověď
- Účel: iterace na promptu beze změny dat = instant hity; statusbar ukáže *"N× cache hit"*
- Invaliduje se automaticky při změně:
  - textu promptu (jediný znak)
  - souboru PDF (jiný hash)
  - vybraného modelu
  - režimu
  - verze cleaneru (bump při update logiky)
- Toggle **Ignorovat cache LLM odpovědí** obchází cache při každém runu

**Vyčistit cache** smaže **obě**.

## Výstupy

Do výstupní složky se ukládá:

**Kanonický formát** (pokud LLM odpověď odpovídá `SHExtractionResult` schema):
- `results.json` — agregát
- per-soubor `{name}.spice-result.json` (deduplikace `{name}_2.spice-result.json`, `{name}_3.spice-result.json` při kolizi) — tyto soubory lze znovu otevřít v aplikaci přes **Otevřít výsledek…** (Cmd+Shift+R) nebo double-click z Finderu
- `results.txt` — human readable + sekce `--- Raw odpověď modelu ---`
- `results.csv` — 1 řádek na dokument, **UTF-8 BOM** pro Excel, LF oddělovače

**Raw výstupy** (vždycky, pro custom schémata):
- `{name}_raw.json` — pokud rawResponse je validní JSON (pretty-printed)
- `{name}_raw.csv` + `{name}_raw.txt` — pokud prompt používá **`=====CSV=====` / `=====TXT=====`** markery (split do dvou souborů)
- `{name}_raw.txt` — fallback pro plain text
- `raw_responses.json` — agregát `{fileName: parsedOrRaw}` napříč všemi dokumenty

`processing.log` — průběžný log (lokální čas, ISO-8601 offset).

## Perzistence mezi spuštěními

Aplikace **záměrně startuje s čistým provozním stavem**: složky, security-scoped bookmarky, text promptu a model selections se při startu resetují. Každá session začíná s prázdným formulářem.

Persistují se:
- **Registry lokálních AI serverů** (jména, URL, API klíče)
- **Vybraný server** (aby ses nemusel pokaždé rozhodovat)
- **Výkonové preference** z Předvoleb: režim extrakce (hlavní okno), workery, throttle, **kontext modelu**, timeout, OCR backend, bypass cache toggle
- **Baseline pro odhady**: průměry z posledního úspěšného runu
- **Výstupní preference**: — (žádné zatím)

Změny se persistují debounced (300 ms) pro textové editace, aby se UserDefaults nezahltily při psaní. Při force-quit aplikace (nebo crashi) se pending změny **flushnou při `willTerminateNotification`**, takže nedojde ke ztrátě editace.

## Nejčastější problémy

### 1) „Vyber inference model"
Není vybraný model. Klikni **Ověřit server** a pak vyber v pickeru **Inference model**.

### 1a) Server je ověřený, ale inference vrací „model not found"
Klikni znovu **Ověřit server** a v pickeru **Inference** vyber model, který se načetl z aktuálního serveru. Aplikace při změně serveru výběry modelů čistí a při ověření neplatný inference model nahrazuje prvním dostupným, ale chyba se může objevit, pokud se model na backendu mezitím odnačetl nebo přejmenoval. V režimu SEARCH stejně zkontroluj i **Embedding** model; některé MLX servery umí chat, ale nemusí vystavovat `/v1/embeddings`.

### 2) „Ověření selhalo"
Zkontroluj **Base URL**, API key a běžící lokální AI server. Retry se u transient chyb (502/503/504/timeout) dělá automaticky s backoffem 1 s → 3 s (max 3 pokusy).

### 3) CONSOLIDATE vrací „Vstup překračuje kontext modelu"
Už se to **nemělo** stát — pipeline při překročení automaticky přejde na **map-reduce**. Uvidíš ve statusbaru např. *"Map-reduce: 16 dok → 4 dávky + 1 reduce"*. Běh trvá déle (K+1 LM volání místo 1), ale projde i pro libovolně velký batch.

Pokud i tak vidíš chybovou hlášku:
- Jednotlivý dokument je sám o sobě větší než kontext modelu → map-reduce to nerozdělí (jeden dokument = jedna dávka). Řešení: v LM Studiu **load model s větším kontextem** (128k, vyžaduje víc RAM).
- Navýš **Kontext modelu** v Předvolbách → Výkon, pokud víš, že tvůj model zvládne víc než defaultních 32k.
- Přepni na **FAST** režim pro per-dokument zpracování bez deduplikace.

### 4) SEARCH je pomalý nebo padá na embeddings
Embedding calls paralelizované, ale stále potřebují funkční embedding endpoint. Po výběru **Embedding** modelu aplikace pošle malý testovací `/v1/embeddings` request a ve statusbaru ukáže buď `Embedding endpoint ověřen`, nebo varování, že SEARCH použije fallback bez RAG. U MLX backendu ověř, že server podporuje `/v1/embeddings` a že vybraný **Embedding** model patří k aktuálnímu serveru. Alternativně vypni embedding model v pickeru a použij **FAST**.

### 4a) Reranker selže
SEARCH pokračuje dál s původním embedding rankingem a zapíše varování do logu. Zkontroluj, že vybraný **Reranker** model patří k aktuálnímu serveru a že backend podporuje `/v1/rerank`.

### 4b) oMLX/VLM OCR je pomalý
VLM OCR posílá každou skenovanou stránku jako obrázek do lokálního modelu, takže je výrazně pomalejší než Apple Vision. Pro běžné skeny používej **Vision→VLM**; čisté **oMLX/VLM** nech pro případy, kdy potřebuješ lepší layout/tabulky nebo Apple Vision selhává.

### 5) Nezobrazují se prompty
Zkontroluj, že složka obsahuje `.md` soubory a byla vybrána přes **Vybrat** (nejenom vepsaná ručně — sandbox vyžaduje security scope, který si appka uloží při výběru přes picker). `.md` soubory se hledají **rekurzivně i v podsložkách**.

### 6) Po updatu appky vidím starou LLM odpověď
Cache key se invaliduje automaticky při změně **verze cleaneru** nebo **schema version**. Ale pokud jen upravíš nestrukturální kód, starý klíč platí. Pokud potřebuješ vynucený re-run, otevři **Předvolby → Cache** (Cmd+,) a klikni **Vyčistit cache** nebo zaškrtni **Ignorovat cache LLM odpovědí**.

### 7) Progress karta ukazuje „Připraveno"
Běh nezačal (preconditions nesplněny). Najeď myší na disabled **Spustit** v toolbaru — tooltip ti vypíše chybějící požadavky („Chybí: server, prompt"). Status bar dole hlásí stejný stav.

### 8) Nefunguje tlačítko Přerušit
Propaguje se `CancellationError` — LLM request se přeruší, pipeline skončí s `.cancelled` outcome. Pokud to zůstane viset déle než 5 s, lokální AI server pravděpodobně zamrzl; restartuj ho.
