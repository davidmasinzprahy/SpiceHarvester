# Klávesové zkratky a menu

## Rychlé příkazy

| Akce | Zkratka |
|---|---|
| Spustit | `Cmd+R` |
| Přerušit | `Cmd+.` |
| Předzpracování | `Cmd+Shift+P` |
| Extrakce | `Cmd+Shift+E` |
| Otevřít výstup ve Finderu | `Cmd+Shift+O` |
| Otevřít výsledek… | `Cmd+Shift+R` |
| Otevřít projekt… | `Cmd+O` |
| Uložit projekt jako… | `Cmd+Shift+S` |
| Nové okno (scratch) | `Cmd+Shift+N` |
| Režim FAST / SEARCH / CONSOLIDATE | `Cmd+1` / `Cmd+2` / `Cmd+3` |
| Fokus filtru logu | `Cmd+F` |
| Zpět (po Vymazat prompt) | `Cmd+Z` |
| Předvolby (výkon, OCR, cache) | `Cmd+,` |
| Nápověda | `Cmd+?` |

## Tab navigace

Mezi aktivními tlačítky cykluje **Tab** / **Shift+Tab** — vlastní `NSEvent` monitor, nezávislý na systémovém *Keyboard Navigation*.

- **Esc** uvolní textové pole a fokus skočí na **Spustit**.

### Menu bar layout

| Menu | Položky |
|---|---|
| **File** | Nové okno (scratch) · Otevřít projekt… · Otevřít nedávné › … · Uložit projekt jako… · Otevřít výsledek… · Otevřít výstup ve Finderu |
| **Pipeline** *(custom top-level)* | Spustit · Přerušit · Předzpracování · Extrakce · Režim FAST / SEARCH / CONSOLIDATE · Znovu ověřit zdraví serveru |
| **Help** | Nápověda Spice Harvester |

Pipeline akce mají vlastní top-level menu (vzor: Xcode Product menu). File menu drží jen project/document operace.
