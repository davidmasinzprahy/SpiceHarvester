# Výkon a cache

## Inference cache

Obří úspora u iterativního ladění promptu. Klíč cache obsahuje:

- systémový prompt (interní) + uživatelský prompt
- verzi cleaneru (`SHTextCleaningService.version`)
- seřazené SHA-256 hashe vstupních PDF
- inference model ID (+ embedding / reranker model ID v SEARCH)
- režim (fast / search / consolidate)
- schema version (`SHInferenceCache.schemaVersion`)

Změna kterékoli části → cache miss → nová inference. Beze změny → instant hit (status bar ukazuje `N× cache hit`).

Toggle **„Ignorovat cache LLM odpovědí"** v **Předvolbách → Cache** (`Cmd+,`) ji vypne (pro non-deterministické modely).

## Výkonový odhad

Po každém úspěšném runu se ukládá `avgPerDocumentMs` a `avgPerPageMs`. Karta **Průběh** v dokončeném stavu i status bar pak před dalším runem informují o době posledního běhu; ETA při běhu se počítá z aktuálních counterů.

## Ladění concurrency

Steppery v **Předvolbách → Výkon** (`Cmd+,`):

1. Zvyš `Souběžné inference požadavky` postupně (2 → 3 → 4).
2. Sleduj stabilitu lokálního AI serveru.
3. Při přetížení zvyš `Throttle mezi požadavky`.
4. `Souběžné PDF/OCR workery` drž mezi `CPU/2` a `CPU`.
5. V CONSOLIDATE se `Souběžné inference` i `Throttle` ignorují (jeden požadavek).

## Čištění cache

- **Předvolby → Cache → Vyčistit cache** smaže JSON soubory per-dokument cache **i** per-inference cache.
- Nebo ručně: smaž obsah cache složky.
