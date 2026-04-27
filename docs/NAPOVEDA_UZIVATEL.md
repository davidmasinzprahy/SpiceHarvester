# Uživatelská nápověda

Tento návod odpovídá aktuálnímu UI aplikace Spice Harvester.

## Layout aplikace

Hlavní okno je dvousloupcové:
- **Vlevo (konfigurace):** Složky · Server a model · Prompt
- **Vpravo (běh):** Průběh · Log

Rozdělovač mezi sloupci lze tahat. **Horní lišta okna (toolbar)** drží stav aplikace (Připraveno / Zpracovávám…) a hlavní akční tlačítka — **Spustit / Přerušit / Výstup / Nápověda**. Dole je **status bar** s podrobnějším textovým stavem.

Pokročilá nastavení (souběžnost, throttle, kontext modelu, timeout, OCR backend, cache) jsou v **Předvolbách** (`Cmd+,`).

## Klávesové zkratky

| Akce | Zkratka |
|---|---|
| Spustit | **Cmd+R** |
| Přerušit | **Cmd+.** |
| Předzpracování | **Cmd+Shift+P** |
| Extrakce | **Cmd+Shift+E** |
| Otevřít výstup ve Finderu | **Cmd+Shift+O** |
| Předvolby | **Cmd+,** |
| Nápověda | **Cmd+?** |

## Rychlý start

1. Spusť **LM Studio** nebo **MLX OpenAI-compatible server** a načti model (doporučeně s co největším kontextem, který ti RAM dovolí).
2. V levém sloupci, sekce **Složky** — nastav cesty:
   - `Vstup` — kde jsou PDF
   - `Výstup` — kam se zapíšou výsledky
   - `Cache` — kde bude JSON cache (může být kdekoli, klidně v projektové složce)
   - `Prompty (.md)` — složka s .md soubory obsahujícími prompty *(volitelné)*

   > **Tip 1:** cestu lze nastavit **přetažením složky z Finderu** přímo do políčka cesty. Tlačítko „Vybrat" / „Změnit" otevře klasický picker.
   >
   > **Tip 2:** po prvním výběru se další picker otevře v nadřazené složce tvého výběru. Sourozenecké složky projektu jsou tak na jeden klik.

3. V sekci **Server a model**:
   - vyber nebo přidej server (výchozí je `http://localhost:1234/v1` pro LM Studio; MLX preset používá `http://localhost:8000/v1`)
   - klikni **Ověřit** — tlačítko zezelená na **Ověřeno**, statusbar ukáže počet modelů a u LM Studia také auto-detekovaný kontext (např. *"modely: 3 · kontext 32k tok."*)
   - vyber **Inference model** z aktuálně načteného seznamu modelů
   - pro SEARCH vyber **Embedding** model; volitelně i **Reranker**
   - pro skenované PDF s VLM OCR vyber i **OCR/VLM** model. (Výběr backendu Apple Vision / oMLX/VLM / Vision→VLM je v **Předvolbách → OCR**.)
4. V sekci **Prompt**:
   - napiš prompt přímo do editoru, nebo
   - klikni **Načíst** a vyber `.md` v pickeru — obsah se vloží do editoru
5. V toolbaru klikni **Spustit** (nebo `Cmd+R`).

## Barvy a co znamenají

- **Zelená** — něco je **ověřené / aktivní / dokončené** (ověřený server, vybraná složka, dokončený run)
- **Modrá** — **akce je spustitelná** (všechny prerekvizity splněny)
- **Šedá (disabled)** — **chybí prerekvizita** (např. `Extrakce` je šedá, dokud nezadáš prompt)
- **Červená** — **destruktivní nebo kritická akce** (Přerušit, Selhalo)
- **Primary** (černá/bílá dle módu) — dekorace, neutralní indikátory

## Co dělají tlačítka

### Toolbar (horní lišta okna)
- **Stav (vlevo)** — zelená tečka + „Připraveno" v idle, spinner + „Zpracovávám…" během běhu.
- **Spustit / Přerušit (Cmd+R / Cmd+.)** — jeden slot, ve kterém se ikona mění podle běhu. „Přerušit" je červené (`role: .destructive`).
- **Výstup (Cmd+Shift+O)** — otevře výstupní složku ve Finderu. Disabled, dokud nemáš nastavenou výstupní složku.
- **Nápověda (Cmd+?)** — otevře help sheet (toto okno).

### Konfigurační sloupec
- **Vybrat / Změnit (folder row)** — otevře `NSOpenPanel`. Cestu lze také jednoduše přetáhnout z Finderu na policko cesty.
- **+ / − server** — přidá / odebere registry položku. Vedle je preset **MLX** (přidá `http://localhost:8000/v1`).
- **Ověřit / Ověřeno (server)** — otestuje lokální OpenAI-compatible server (`/v1/models`), načte seznam modelů a u LM Studia navíc přes `/api/v0/models` auto-nastaví **Kontext modelu** ze skutečné hodnoty `loaded_context_length`. U MLX/obecných backendů status bar ukáže `kontext ručně` a hodnotu nastavíš v **Předvolbách → Výkon**. Po přepnutí mezi LM Studio/MLX aplikace vyčistí předchozí model selections; po ověření zkontroluj **Inference** i **Embedding** picker proti nově načtenému seznamu. Při úspěchu zůstává **zelené "Ověřeno"** dokud nezměníš URL / API key / vybraný server.
- **Načíst (prompt)** — oskenuje prompt folder, naplní picker souborů (`.md`).
- **nothink / think** — vloží do promptu instrukci `/no_think` nebo `/think` pro modely, které tento režim podporují (Qwen3, DeepSeek-R1).
- **Vymazat (prompt)** — vyčistí editor promptu.

### Menu File (klávesové zkratky)
- **Spustit (Cmd+R)** — alias k toolbar buttonu.
- **Přerušit (Cmd+.)** — propaguje `CancellationError` do pipeline; běžící LLM požadavek se zruší.
- **Předzpracování (Cmd+Shift+P)** — spustí pouze FÁZI 1 (scan/hash/cache/PDF/OCR/clean).
- **Extrakce (Cmd+Shift+E)** — spustí pouze FÁZI 2 (LLM extrakce nad cache); automaticky doplní předzpracování, pokud ještě nejsou data.

### Runtime sloupec
- **Hotovo / Přerušeno / Selhalo (completion banner)** — po dokončení runu se objeví nahoře v pravém sloupci. Klik na **Potvrdit** banner skryje a vrátí UI do připraveného stavu.
- **Obnovit (log)** — načte aktuální tail `processing.log` z disku. Užitečné při dlouhém runu, kdy chceš nahlédnout na živý log dřív, než skončí aktuální fáze.

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
- **OCR backend** — `Apple Vision` běží lokálně bez AI serveru; `oMLX/VLM` posílá skenované stránky vybranému OCR/VLM modelu; `Vision→VLM` použije VLM jako fallback pro stránky, kde Vision nevrátí použitelný text.

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
- per-soubor `{name}.json` (deduplikace `{name}_2`, `{name}_3` při kolizi)
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
Zkontroluj **Base URL**, API key a běžící lokální AI server. Retry se u transient chyb (502/503/504/timeout) dělá automaticky s backoffem 1 s → 3 s → 9 s.

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
Zkontroluj, že složka obsahuje `.md` soubory a byla vybrána přes **Vybrat** (nejenom vepsaná ručně — sandbox vyžaduje security scope, který si appka uloží při výběru přes picker).

### 6) Po updatu appky vidím starou LLM odpověď
Cache key se invaliduje automaticky při změně **verze cleaneru** nebo **schema version**. Ale pokud jen upravíš nestrukturální kód, starý klíč platí. Pokud potřebuješ vynucený re-run, otevři **Předvolby → Cache** (Cmd+,) a klikni **Vyčistit cache** nebo zaškrtni **Ignorovat cache LLM odpovědí**.

### 7) Progress karta ukazuje „Připraveno"
Běh nezačal (preconditions nesplněny). Najeď myší na disabled **Spustit** v toolbaru — tooltip ti vypíše chybějící požadavky („Chybí: server, prompt"). Status bar dole hlásí stejný stav.

### 8) Nefunguje tlačítko Přerušit
Propaguje se `CancellationError` — LLM request se přeruší, pipeline skončí s `.cancelled` outcome. Pokud to zůstane viset déle než 5 s, lokální AI server pravděpodobně zamrzl; restartuj ho.
