# UI Design – Spice Harvester

Dokumentace vizuálních a interakčních prvků macOS aplikace. Zdroj: [ContentView.swift](../SpiceHarvester/ContentView.swift), [SpiceHarvesterApp.swift](../SpiceHarvester/SpiceHarvesterApp.swift), [Views/](../SpiceHarvester/Views/). Framework: **SwiftUI**, cílová platforma **macOS 15+** (AppKit integrace přes `NSApplicationDelegateAdaptor`, nativní `Settings` Scene).

> **Design language:** *Compact Glass*. Translucentní karty (`.regularMaterial`) s minimálním paddingem a tenkou hierarchií. Cílem je vidět co nejvíc pipeline stavu najednou, bez zbytečného prázdného místa. Viz §28.

---

## 1. Celkový layout

### Okno
- Minimální velikost: **980 × 680 px** (`.frame(minWidth: 980, minHeight: 680)`).
- Defaultní velikost při první spuštění: **1180 × 980 px** (`.defaultSize`).
- Při každém spuštění `SHAppDelegate` nastaví okno podle aktuálního `NSScreen.visibleFrame`: výška vždy využije celé dostupné místo mezi menu barem a Dockem, aby se při startu minimalizoval vertikální scrollbar. Na velkém monitoru se omezuje jen šířka na **1320 pt**, na menších monitorech se používá preferovaná šířka **1200 pt** capped šířkou obrazovky.

### Window toolbar (`.toolbar`)
Stálá horní lišta okna (macOS-native NSToolbar pod kapotou). Obsahuje:

| Slot | Obsah |
|---|---|
| `.navigation` (vlevo) | **Status indikátor** – `ProgressView(.small)` + „Zpracovávám…" při běhu, jinak zelená tečka 9 pt + „Připraveno". |
| `.primaryAction` (vpravo) | **Spustit** (`play.fill`, prominent) — nebo **Přerušit** (`stop.circle.fill`, destructive role) pokud `vm.isRunning`. **Výstup** (`folder`). **Nápověda** (`questionmark.circle`). |

Toolbar je **single source of truth** pro Run/Stop. Při běhu se Run automaticky přepíná na Stop ve stejném slotu (žádný layout jump). Output je vždy přítomný (disabled, pokud není výstupní složka). Help otevírá sheet.

### Hlavní layout (`HSplitView`)
Pod toolbarem je dvousloupcový `HSplitView`. Rozdělovač je tažitelný; dovnitř každého sloupce je `padding(14)`.

**Levý sloupec — konfigurace** (min 540 pt, ideal 620 pt, vlastní `ScrollView`):
1. Header (logo + název + subtitle)
2. Složky (`foldersCard`)
3. Server a model (`serverCard` — **bez** výkonu / OCR backendu / timeoutu)
4. Prompt (`promptsCard` + conflict bannery)

**Pravý sloupec — runtime** (min 420 pt, **bez** outer ScrollView):
1. Completion banner (jen pokud `vm.lastCompletion != nil`)
2. Průběh (`progressStatusCard`)
3. Log (`logCard`, `frame(maxHeight: .infinity)`)

**Status bar** je pod oběma sloupci, plné šířky.

### Pozadí
Diagonální **LinearGradient** z `.windowBackgroundColor` (topLeading) do `Color.accentColor.opacity(0.07)` (bottomTrailing). Jemné zabarvení akcentní barvou, ne agresivní. `.ignoresSafeArea()`.

### Settings Scene (Cmd+,)
Druhá `Scene` v `SpiceHarvesterApp.body`. Otevírá nativní macOS Settings okno. Horní přepínač tabů je vlastní SwiftUI `HStack` s ikonovými buttony, protože systémový macOS `TabView` kreslil vybraný item ve světlém režimu bílým textem na světlém pozadí. Obsah jednotlivých tabů zůstává `Form { Section { … } }` s `.formStyle(.grouped)`.

| Tab | Symbol | Obsah |
|---|---|---|
| Výkon | `speedometer` | Souběžné inference / PDF-OCR workery, throttle, kontext modelu, timeout požadavku |
| OCR | `doc.text.viewfinder` | OCR backend (`Picker(.inline)`) — Apple Vision / oMLX/VLM / Vision→VLM, s vysvětlujícím footerem |
| Cache | `externaldrive` | Toggle „Ignorovat cache LLM odpovědí", Vyčistit cache (`role: .destructive`) |

Frame: **620 × 540 pt**. Sdílí `vm` s hlavním oknem přes `@State` na úrovni App scene.

Tab selector:
- Nad přepínačem je titul aktivního tabu (`.title2.bold`, `.primary`).
- Každý tab button má **76 × 76 pt**, ikonu 27 pt a text `.title3`.
- Vybraný tab používá `.primary`, jemný `Color.primary.opacity(0.06)` background a 1 pt stroke `Color.primary.opacity(0.12)`.
- Nevybrané taby používají `.secondary`.

### Commands menu (`.commands`)
SpiceHarvesterApp registruje dvě skupiny:
- `CommandGroup(replacing: .newItem)` — Spustit / Přerušit / Předzpracování / Extrakce / Otevřít výstup
- `CommandGroup(replacing: .help)` — „Nápověda Spice Harvester" (Cmd+?)

Klávesové zkratky:

| Akce | Zkratka |
|---|---|
| Spustit | `Cmd+R` |
| Přerušit | `Cmd+.` |
| Předzpracování | `Cmd+Shift+P` |
| Extrakce | `Cmd+Shift+E` |
| Otevřít výstup | `Cmd+Shift+O` |
| Předvolby | `Cmd+,` (system default) |
| Nápověda | `Cmd+?` |

Disabled stav položek se řídí `vm.canRunAll`, `vm.canRunPreprocessing`, `vm.canRunExtraction`, `vm.canOpenOutput`, `vm.isRunning`.

### Help sheet
Modální sheet otevíraný z toolbar tlačítka i z menu (Cmd+?). Obsahem dokumentace `Co aplikace dělá / Co si připravit / Postup / Režimy / Tipy`. Detail viz §27.

---

## 2. Barevná paleta

Aplikace používá systémové sémantické barvy – ladí se automaticky s **Light/Dark mode** a s uživatelským akcentem v macOS.

| Role | Barva | Použití |
|---|---|---|
| **Primární akce** | `.blue` | Běžná tlačítka, verify, načíst, refresh, „Spustit" v toolbaru |
| **Prominentní akce** | `.blue` + `.borderedProminent` | (rezervováno; v hlavním okně už nemáme prominentní button — Run je v toolbaru) |
| **Úspěch / potvrzení** | `.green` | Vybraná složka (ikona), ověřený server, „Hotovo", řádek „Dokončeno", status indicator dot |
| **Destruktivní** | `.red` | Tlačítko „Přerušit" v toolbaru, „Vyčistit cache" v Settings |
| **Přerušeno** | `.gray` | Completion banner po přerušení |
| **Varování (warn)** | `.yellow` | Banner `modeMismatch` (lightbulb) |
| **Varování (error)** | `.orange` | Banner `searchModeWithoutEmbeddingModel`, health `.stuck` |
| **Info** | `.blue` | Banner `consolidateIgnoresConcurrency` |
| **Sekundární text** | `.secondary` | Popisky, subtitle, captions, em-dash placeholdery |
| **Terciární text** | `.tertiary` | Placeholder v TextEditoru, `—` v idle folder rowech |
| **Systémové BG** | `Color(nsColor: .windowBackgroundColor)` | Základ gradientu |
| **Akcent** | `Color.accentColor` | Tón gradientu, výchozí macOS akcent |

Conflict bannery a completion banner používají vzor **`tint.opacity(0.10)` fill + `tint.opacity(0.35)` stroke** – semi-transparentní, nerušivé.

---

## 3. Typografie

| Element | Font | Váha |
|---|---|---|
| Hlavní název aplikace | `.title2` | `.bold` |
| Nadpis karty | `.subheadline` | `.semibold` (secondary tint) |
| Label v řádku složky | `.body` | `.medium` |
| Toolbar status text | `.callout` | default (secondary) |
| Název konfliktu / completion banner | `.footnote` / `.subheadline` | `.semibold` |
| Zpráva konfliktu | `.caption` | — |
| Popisky (label, caption v kartě) | `.caption` | default |
| Subtitle pod názvem | `.caption` | default |
| Status bar | `.caption` | default |
| Mode caption pod segmented | `.caption` | default (secondary) |
| Monospace (cesty, URL, log, prompt) | `.system(design: .monospaced)` | — |
| Log | `.system(size: 10.5, design: .monospaced)` | — |
| Prompt editor | `.system(size: 12, design: .monospaced)` | — |
| Číselné hodnoty ve statRow | `.caption.monospacedDigit()` | `.medium` |

**Lokalizace:** všechny labely jsou v češtině (fixně, žádný `.strings`).

---

## 4. Ikonografie

Používá se **SF Symbols** (`Image(systemName:)`). Ikony nesou sémantický význam a jsou doprovodem textového labelu (vzor `Label(text, systemImage:)`).

### Mapování – toolbar / commands
| Akce | Symbol |
|---|---|
| Spustit | `play.fill` |
| Přerušit | `stop.circle.fill` |
| Otevřít výstup | `folder` |
| Nápověda | `questionmark.circle` |

### Mapování – v levém sloupci (konfigurace)
| Akce / objekt | Symbol |
|---|---|
| Karta Složky | `folder.fill` |
| Vstup | `tray.and.arrow.down.fill` |
| Výstup | `tray.and.arrow.up.fill` |
| Cache | `externaldrive.fill` |
| Prompty | `doc.text.fill` |
| Karta Server | `server.rack` |
| Add server | `plus.circle.fill` |
| Remove server | `minus.circle.fill` |
| MLX preset | `apple.logo` |
| Verify server | `checkmark.seal` → `checkmark.seal.fill` (po ověření) |
| Karta Prompt | `text.quote` |
| Načíst prompty | `arrow.down.doc.fill` |
| nothink mód | `bolt.fill` |
| think mód | `brain.head.profile` |
| Vymazat prompt | `xmark.circle` |

### Mapování – v pravém sloupci (runtime)
| Stav | Symbol |
|---|---|
| Karta Průběh | `chart.bar.fill` |
| Idle | `pause.circle.fill` |
| Předzpracování (fáze) | `doc.text.magnifyingglass` |
| Extrakce fáze | `brain` |
| Karta Log | `text.alignleft` |
| Refresh log | `arrow.clockwise` |

### Mapování – stavové a konfliktní ikony
| Stav / konflikt | Symbol | Barva |
|---|---|---|
| Mode mismatch | `lightbulb.fill` | `.yellow` |
| Search bez embed modelu | `exclamationmark.triangle.fill` | `.orange` |
| Consolidate ignoruje concurrency | `info.circle.fill` | `.blue` |
| Hotovo | `checkmark.circle.fill` | `.green` |
| Přerušeno | `xmark.circle.fill` | `.gray` |
| Selhalo | `exclamationmark.triangle.fill` | `.red` |
| Health `.starting` | `hourglass.circle.fill` | `.blue` |
| Health `.ok` | `checkmark.circle.fill` | `.green` |
| Health `.stuck` | `exclamationmark.triangle.fill` | `.orange` |
| Health `.finished` | `checkmark.seal.fill` | `.green` |

### Režim extrakce (hint ikona pod labelem)
| Režim | Symbol |
|---|---|
| FAST | `bolt.fill` |
| SEARCH | `magnifyingglass` |
| CONSOLIDATE | `square.stack.3d.up.fill` |

### Settings tabs
| Tab | Symbol |
|---|---|
| Výkon | `speedometer` |
| OCR | `doc.text.viewfinder` |
| Cache | `externaldrive` |

### Help sheet – ikony sekcí
| Sekce | Symbol |
|---|---|
| Co aplikace dělá | `sparkles` |
| Co si připravit | `wrench.and.screwdriver.fill` |
| Postup | `list.number` |
| Režimy | `slider.horizontal.3` |
| Tipy | `lightbulb.fill` |

### Renderování
`GlassCard` hlavní ikona používá `.symbolRenderingMode(.hierarchical)` pro jemně odstupňovanou sytost. Stejně tak status indikátory v toolbaru a kartě Průběh.

---

## 5. Komponenty

### 5.1 `GlassCard` (sdílený kontejner)
Bílá matná karta s frosted-glass efektem. Použita pro **každou sekci** hlavního layoutu. **Compact varianta** – minimální padding, tenká hierarchie. Zdroj: [Views/GlassCard.swift](../SpiceHarvester/Views/GlassCard.swift).

- Pozadí: `.regularMaterial` (macOS blur podklad)
- Tvar: `RoundedRectangle(cornerRadius: 10, style: .continuous)`
- Border: `Color.primary.opacity(0.06)`, lineWidth 0.5
- **Bez stínu** – stínové vrstvy přes 5+ karet na window-sized gradientu šuměly bez přidaných informací; `.regularMaterial` + tenký stroke je dostatečné oddělení.
- Padding: **12 pt**
- VStack spacing: **8 pt**
- Header: `HStack(spacing: 6)` – ikona (`.caption`, `.secondary`, hierarchická) + `title` (`.subheadline.weight(.semibold)`, `.secondary`)

**Hlavička karty je tlumená** (oba prvky `.secondary`) – nekrade pozornost obsahu.

### 5.2 Header levého sloupce
- `AppLogo` **36×36**, `RoundedRectangle(cornerRadius: 8)`, subtle border 0.5 pt.
- Název `Spice Harvester` (`.title2` bold) + subtitle **„Nástroj pro hromadné vytěžování dat z dokumentů"** (`.caption`, secondary).
- HStack spacing: **10 pt**.
- **Žádný „Zpracovávám…" pill, žádný help button** — obojí je v window toolbaru (§1).

### 5.3 Řádek složky (`folderRow`)
**Read-only path + drag-and-drop**. Cesty se na macOS nepíšou rukou, takže textfield je pasivní zobrazovač s drop-targetem.

- Label (ikona + název, **width 130 pt**). Ikona **zelená** pokud je složka vybraná (`!path.isEmpty`), jinak `.secondary`.
- Path display: `Text` v rounded boxu (`.quinary` bg + 0.5 pt stroke), monospace, `lineLimit(1) .truncationMode(.middle)`. Idle stav = `—` v `.tertiary` barvě. Plná cesta v `.help(...)` tooltipu.
- Drop target: `.dropDestination(for: URL.self) { urls, _ in … }` přes path display. Akceptuje pouze **adresáře** (kontrola `FileManager.fileExists(atPath:isDirectory:)` + `isDir.boolValue`).
- Tlačítko vpravo: `.bordered`, vždy `.blue` tint. Label se mění **„Vybrat" → „Změnit"** podle stavu, ale styl zůstává konzistentní (vizuální stavová informace nese ikona vlevo). Min šířka 64 pt.
- Kliknutí vždy otevře `NSOpenPanel`.

### 5.4 Server registry
- `Picker` flexibilní šířky (bez fixních 260 pt — sloupec se může měnit). Při změně serveru se ruší „Ověřeno" stav (`invalidateServerVerification`).
- Add / Remove tlačítka: `.borderless`, `plus.circle.fill` / `minus.circle.fill`, font `.title3`, tint `.blue`. Mají `.help` a `.accessibilityLabel`.
- MLX preset tlačítko: `.bordered`, `.controlSize(.small)`, `apple.logo` + text `MLX`. Přidá server `Local MLX` s Base URL `http://localhost:8000/v1`.
- **Verify button** (pravý horní roh stejného řádku):
  - `canVerifyServer == false` → disabled.
  - Neověřeno → `.bordered` tint `.blue`, label „Ověřit".
  - Ověřeno → `.bordered` tint `.green`, label „Ověřeno", `checkmark.seal.fill`. Klik = re-verify.
- TextField název / Base URL / SecureField API Key – všechny `.roundedBorder`. URL a API key editace invaliduje ověření.
- Model pickery v **`Grid(2×2)`**: `Inference` + `Embedding` v první řadě, `Reranker` + `OCR/VLM` v druhé. Šířka pickerů roste s obsahem (ne fixní 320 pt) — užší levý sloupec by 320 pt nepojal.
- **Žádný OCR backend picker, žádné Steppery** — přesunuto do Settings (§1, §28.3).
- **Režim extrakce** (`modeRow`): caption „Režim extrakce" + hint ikona, segmented `Picker`, **vícřádkový popis aktivního režimu pod pickerem** (`modeHintText` v `.caption .secondary`, `fixedSize(vertical: true)`). Vpravo malá `.tertiary` poznámka „Pokročilá nastavení v Předvolbách (Cmd+,)" jako wayfinding.

### 5.5 Prompt editor
- Horní lišta: tlačítko **„Načíst"** (`.bordered` blue, disabled podle `canLoadPrompts`), picker se soubory (max 240 pt) nebo fallback hláška ve **Capsule** (`.quaternary` bg).
- Dvojice tlačítek **„nothink"** / **„think"** (`.bordered` `.controlSize(.small)`) — aktivní mód má green/orange tint, nečinný blue.
- Tlačítko **„Vymazat"** (`.borderless` blue) – zobrazí se jen pokud existuje text.
- `TextEditor` monospace 12 pt, minHeight 160 / maxHeight 280, `.scrollContentBackground(.hidden)`, bg `.quinary` s `cornerRadius 6`, subtle border 0.5 pt.
- Placeholder přes ZStack: „Zadej prompt…" `.tertiary` barvou, `.allowsHitTesting(false)` (text-field pozadí zůstává klikatelné).

### 5.6 Conflict banner
Jemné upozornění na rozpor konfigurace a promptu.
- Horizontální layout: ikona (callout, tintová) + VStack(title footnote semibold + message caption secondary) + Spacer + action button.
- Pozadí: `tint.opacity(0.10)` v `RoundedRectangle(8)`, border `tint.opacity(0.35)` 0.5 pt.
- **Akce banneru NEexekutuje přímo** – uloží konflikt do `pendingConflict` (view `@State`) a otevře `.confirmationDialog` (obrana proti false-positive heuristice).
- Dialog: akční tlačítko + `Button("Zrušit", role: .cancel)`.

### 5.7 Completion banner (pravý sloupec, top)
Persistentní acknowledge řádek po skončení runu. Nahrazuje původní completion button v Akce baru – s toolbarem ovládajícím Run/Stop nemá completion v hlavním okně logické místo v toolbaru, tak dostala vlastní spot v runtime sloupci.

| Outcome | Ikona | Barva | Title |
|---|---|---|---|
| `.success` | `checkmark.circle.fill` | `.green` | „Hotovo" |
| `.cancelled` | `xmark.circle.fill` | `.gray` | „Přerušeno" |
| `.failed` | `exclamationmark.triangle.fill` | `.red` | „Selhalo" |

Layout: `HStack { icon · title · Spacer · Button("Potvrdit") }`, padding 12/8, `tint.opacity(0.10)` fill + 0.35 stroke. Klik na „Potvrdit" volá `vm.acknowledgeCompletion()` a banner mizí.

### 5.8 Průběh (`progressStatusCard`)

**Pravý sloupec, hlavní indikátor běhu.** Používá `TimelineView(.periodic(by: 1.0))` aby „uplynulo / ETA / X s bez pokroku" tikalo i bez counter eventu.

Tři stavy podle `SHProgressPhase`:

| Phase | Obsah |
|---|---|
| `.idle` | `pause.circle.fill` + `„Připraveno – spusťte zpracování tlačítkem Spustit v horní liště (Cmd+R)."` (bez progress baru). |
| `.preprocessing` / `.extraction` | Header (ikona fáze + název + %), `ProgressView(value:)` modrý, řádek „N/M · Uplynulo: T", divider, „Zbývá: ETA", health row. Název fáze: „Předzpracování (OCR + extrakce textu)" / „Extrakce (AI inference)". |
| `.finished` | Outcome ikona + „Hotovo / Přerušeno / Selhalo / Ukončeno" + summary „N/M dokumentů · trvalo T" nebo „N/M LM kroků". |

#### 5.8.1 Health indikátor (detekce zaseknutí)

Poslední řádek karty během běhu. Hodnota vychází z `SHProgressViewState.health(now:stuckAfter:graceAfter:)`:

| Health | Ikona | Barva | Text |
|---|---|---|---|
| `.starting` | `hourglass.circle.fill` | `.blue` | „Inicializace – čekám na první dokument…" |
| `.ok` (čerstvý pokrok) | `checkmark.circle.fill` | `.green` | „Vše v pořádku · aktualizuje se právě teď" |
| `.ok` (pokrok před X s) | `checkmark.circle.fill` | `.green` | „Vše v pořádku · poslední pokrok před X s" |
| `.stuck` (žádný pokrok po grace) | `exclamationmark.triangle.fill` | `.orange` | „Bez pokroku – zkontrolujte server v LM Studiu" |
| `.stuck` (silent > prahu) | `exclamationmark.triangle.fill` | `.orange` | „Zdá se, že je zpracování pozastavené (X s bez pokroku)" |

**Thresholds:**
- `stuckAfter: 30 s` – po 30 s bez inkrementu countru se klopí `.ok` → `.stuck`.
- `graceAfter: 15 s` – startup grace pro první counter (během scan + server warmup).

**Counter tracking:** `applyCounters(_:)` ve viewmodelu nastaví `lastProgressAt = Date()` jen pokud jedna z hodnot (`completed`, `cachedDocs`, `newlyOCRed`, `foundPDFs`) skutečně narostla.

#### 5.8.2 Fáze a metrika pokroku

| Fáze | Čitač pro % | Ikona v headeru |
|---|---|---|
| preprocessing | `cachedDocs / foundPDFs` | `doc.text.magnifyingglass` |
| extraction | `extractionProgressCompleted / extractionProgressTotal` | `brain` |

ETA se přepočítá přes `recalculateEta()` – vybere správný čitač podle `phase`.

### 5.9 Log card
- `Text` (nikoli TextEditor) v ScrollView → neztrácí cursor při re-renderingu a umožňuje auto-scroll na konec.
- Monospace 10.5 pt, `.textSelection(.enabled)` (copy-paste povoleno).
- Auto-scroll na nový obsah přes `ScrollViewReader.scrollTo("logBottom", anchor: .bottom)` s `withAnimation(.easeOut(duration: 0.15))`.
- **Refresh button** (`Label("Obnovit", systemImage: "arrow.clockwise")`, `.borderless` blue, `.controlSize(.small)`) zarovnaný vpravo nad scroll plochou — `vm.logText` se z disku obnovuje až mezi fázemi, takže během dlouhého runu uživatel potřebuje manuální tail re-read.
- Log scroll plocha: `frame(minHeight: 200, maxHeight: .infinity)` — využije celou zbylou výšku pravého sloupce (hostuje `frame(maxHeight: .infinity)` na celé kartě).
- Bg `.quinary` + cornerRadius 6.
- Pravý sloupec **není** wrapnutý v outer `ScrollView`, takže log scroll vlastní gesta bez konfliktu s rodičovským scrollem (typický macOS footgun u nested ScrollView byl odstraněn).

### 5.10 Status bar (dolní lišta)
- Výška ≈ textu + `padding(horizontal: 12, vertical: 5)`.
- Indikátor vlevo:
  - Running → `ProgressView(.mini)`, accessibility „Probíhá zpracování".
  - Idle → zelená tečka `circle.fill` **10 pt**, accessibility „Připraveno".
- `vm.statusText` (caption, lineLimit 1, truncationMode `.middle`).
- Pozadí `.thinMaterial` + horní `Divider` overlay.

---

## 6. Vzory chování tlačítek

### Button styly
| Styl | Kdy |
|---|---|
| `.borderedProminent` | Settings „destructive" Vyčistit cache (přes `role`). V hlavním okně se neprominuje, primární CTA žije v toolbaru. |
| `.bordered` | 80 % tlačítek – sekundární akce (Načíst, Verify, Vybrat/Změnit, „nothink/think", „Potvrdit" u completion banneru, „Obnovit" log) |
| `.borderless` | Ikonická / inline tlačítka (+/− server, „Vymazat" prompt, refresh log icon) |
| toolbar default | Run / Stop / Output / Help — bez explicitního stylu, NSToolbar řeší vizuál |

### Stavové flipy (stejné tlačítko, jiný tint/label/ikona)
Silný UX vzor – tlačítko **nemění pozici**, mění vzhled:
- **Vybrat / Změnit** ve folder rowech (label se mění, tint i ikona zůstávají — stavovou informaci nese **zelená ikona vlevo**, ne tlačítko)
- **Ověřit / Ověřeno** (blue checkmark.seal → green checkmark.seal.fill)
- **Spustit (toolbar) → Přerušit (toolbar)** — ve stejném slotu se mění z `play.fill` `.primary` na `stop.circle.fill` `.destructive`

### Disabled stav
`.disabled(!condition)`, kde `condition` je computed property na view modelu (`canRunAll`, `canVerifyServer`, `canLoadPrompts`, `canOpenOutput`, …). Disabled tlačítka si ponechávají pozici a barevný tint – signalizují „existuje, ale zatím nepoužitelné".

### Tooltips (`.help`)
Přítomné u **všech** nezřejmých tlačítek a stepperů. Píšou se česky, obsahují věcné vysvětlení (nikoli repeat labelu) a často odkazují na klávesovou zkratku.

**Akční tlačítka mají dvojí tooltip:**
- Enabled → popis akce (často s klávesovou zkratkou: „Spustí kompletní pipeline (Cmd+R)").
- Disabled → seznam chybějících requirementů (viz §15.1).

Tooltip funguje i na disabled stavu – je to primární kanál, jak uživateli sdělit, proč tlačítko nelze kliknout.

### Accessibility
- `.accessibilityLabel` tam, kde ikona nese jediný sémantický obsah (+/− server, status indikátor, drop targety).
- VoiceOver-friendly labely v status baru obsahují plný stav: „Stav: {statusText}".

---

## 7. Odstupy a rozměry (spacing tokens)

| Kontext | Hodnota |
|---|---|
| Padding sloupce v HSplitView | **14 pt** |
| Spacing mezi kartami v sloupci | **10 pt** |
| Padding uvnitř GlassCard | **12 pt** |
| VStack spacing v GlassCard | **8 pt** |
| Spacing v řádcích karet | **6 – 10 pt** |
| Spacing v labelech / ikonách | **6 pt** |
| Corner radius karet | **10 pt** |
| Corner radius logo | **8 pt** |
| Corner radius prompt editor / log / folder path / completion banner | **6 – 10 pt** |
| Corner radius conflict banner | **8 pt** |
| Border width | 0.5 pt (jemný) |
| Stín karty | **odstraněn** (viz §28) |
| Stín loga | odstraněn (jen tenký border) |

---

## 8. Animace

Minimalistické – jediný explicitní `withAnimation` je **log auto-scroll** (`easeOut 0.15s`). Ostatní přechody (state flipy tlačítek, objevení conflict banneru, toolbar Run↔Stop) používají výchozí implicitní SwiftUI animace.

---

## 9. Interaction principy

1. **Reverzibilita destruktivních akcí** – conflict banner neaplikuje změnu přímo, vyžaduje `.confirmationDialog`. Vyčistit cache je v Settings, vzdálená od „Spustit".
2. **Žádné dvojité potvrzení nežádoucích akcí** – „Přerušit" je akceptováno klikem (cancel je reverzibilní).
3. **Silný vizuální feedback** – stavové flipy, zelená pro „OK/hotovo", červená výhradně pro stop/failure.
4. **Em-dashe místo nul** – prázdný stav je vizuálně odlišný od „0 nalezeno".
5. **Konzistentní vzor `Label(text, systemImage:)`** – nikdy samostatná ikona bez textu u primárních akcí.
6. **Disabled místo mizejících tlačítek** – pozice tlačítek v toolbaru/sekcích se mění pouze u toolbar Run↔Stop a u ošetřených state machines (verify, folder row).
7. **Automatická persistence** – všechny changes jdou přes `persistAll()` nebo `persistAllDebounced()` hned po změně, jak v hlavním okně, tak v Settings.
8. **macOS-native first** – Settings Scene přes `Settings { … }`, klávesové zkratky přes `.commands`, drag&drop přes `.dropDestination(for:)`. Žádné vlastní okénka tam, kde existuje systémový pattern.

---

## 10. Konvence prázdných stavů a placeholderů

| Kontext | Placeholder |
|---|---|
| Folder path display | `—` (em-dash, `.tertiary`) |
| TextEditor prompt | `Zadej prompt…` (tertiary) |
| Picker inference model | `-- vyber --` |
| Picker embedding model | `-- vypnuto --` |
| Picker prompt soubor | `— vyber —` |
| Picker server | název serveru (nikdy není prázdný, registry má vždy ≥ 1 server) |
| Log prázdný | `" "` (mezera – vynuceno, aby ScrollView neměl nulovou výšku) |
| Progress hodnoty v idle | `—` (em-dash) |
| Žádné prompt soubory | Capsule chip „Ve složce zatím žádné .md" na `.quaternary` pozadí |

**Pravidlo:** prázdný stav zobrazuje vždy viditelný textový marker, nikoli zmizené pole nebo nulu. Čísla = data; pomlčka = idle.

---

## 11. Material hierarchie

SwiftUI materials jsou použity s jasnou sémantikou:

| Material | Použití | Důvod |
|---|---|---|
| `.regularMaterial` | Pozadí `GlassCard` | Nejvyšší krytí – hlavní kontejnery |
| `.thinMaterial` | Status bar, header/footer help sheetu | Odlehčené, ale pořád čitelné přes gradient |
| `.quinary` | Bg prompt editoru, bg logu, bg folder path display | Nejmenší kontrast – „textarea" look |
| `.quaternary` | Empty-state chip (prázdná promptová složka) | Lehce víc kontrastu než `.quinary`, ale stále jemné |

**Nikdy nepoužívat `.ultraThinMaterial` ani `.thickMaterial`** – aplikace udržuje jednotný dvojstupňový blur (regular pro karty, thin pro lišty).

---

## 12. Frame tokeny

| Prvek | Hodnota |
|---|---|
| Label ve folder row (ikona + text) | **130 pt** šířka |
| Folder row tlačítko Vybrat/Změnit | min **64 pt** |
| Picker prompt souboru | **max 240 pt** |
| Levý sloupec HSplitView | min **540 pt**, ideal **620 pt** |
| Pravý sloupec HSplitView | min **420 pt** |
| Ikona ve statRow | **14 pt** |
| Logo | **36 × 36 pt** |
| Min šířka okna | **980 pt** |
| Min výška okna | **680 pt** |
| Default šířka okna při prvním launchi | **1180 pt** |
| Default výška okna při prvním launchi | **980 pt** |
| Preferred šířka okna při launchi | **1200 pt** compact / **1320 pt** large screen |
| Výška okna při launchi | `screen.visibleFrame.height` |
| Settings sheet | **620 × 540 pt** |
| Help sheet | min **640 × 600**, ideal **720 × 780**, max **900 × ∞** |

Modelové pickery a server picker už **nemají fixní šířku** — flexnou se uvnitř Gridu/HStack pod limitem sloupce. Steppery a OCR backend picker mají vlastní layout v Settings (Form `.grouped`).

---

## 13. Binding patterns

### Read-only binding z modelu
```swift
TextField("...", text: $vm.config.inputFolder)
```

### Binding se side-effectem (invalidace závislého stavu)
Použit, když změna jedné hodnoty musí resetovat druhou:
```swift
TextField("Base URL", text: Binding(
    get: { vm.servers[idx].baseURL },
    set: {
        vm.servers[idx].baseURL = $0
        vm.serverConnectionDetailsChanged()  // ← reset Ověřeno + clear models
    }
))
```

### Binding s early-exit kontrolou
Použit u Picker pro server – kontroluje, zda se index **skutečně** změnil před invalidací:
```swift
Picker("Server", selection: Binding(
    get: { vm.selectedServerIndex },
    set: { newValue in
        if newValue != vm.selectedServerIndex {
            vm.invalidateServerVerification()
        }
        vm.selectedServerIndex = newValue
    }
))
```

### Drag-and-drop binding
Pro folder rows: drop závěr aktualizuje stejný stav, jaký by setnul picker.
```swift
.dropDestination(for: URL.self) { urls, _ in
    guard let first = urls.first,
          first.hasDirectoryPath else { return false }
    onDrop(first.path)            // ← stejný callback jako picker
    return true
}
```

### `@Bindable` v subviews
ContentView a SettingsView dostanou `vm` z App scene. Aby mohly použít `$vm.config.x` bindings, deklarují property jako `@Bindable var vm: SHAppViewModel`. Žádný `@StateObject` ani `@ObservedObject` — `SHAppViewModel` je `@Observable` (Observation framework).

---

## 14. Persistence patterns (onChange)

Hodnoty se ukládají automaticky na změně, **bez tlačítka Save**.

### Debounced – pro rychle se měnící hodnoty
```swift
.onChange(of: vm.config.currentPrompt) { _, _ in
    vm.persistAllDebounced()
}
```
Použití: text v TextEditoru, rename serveru, drop nové cesty.

### Immediate – pro diskrétní volby
```swift
.onChange(of: vm.config.extractionMode) { _, _ in vm.persistAll() }
```
Použití: pickery, toggle, stepper, segmented control. **Stepper handlery žijí v `SettingsView`** (Výkon tab) — `maxConcurrentInference`, `maxConcurrentPDFWorkers`, `throttleDelayMs`, `modelContextTokens`, `bypassInferenceCache`.

### S vedlejším efektem (rebuild klienta)
```swift
// V SettingsView – Výkon tab
.onChange(of: vm.config.requestTimeoutSeconds) { _, _ in
    vm.rebuildLMClient()   // URLSessionConfiguration je immutable po vytvoření
    vm.persistAll()
}
```

### Kaskádová invalidace
```swift
.onChange(of: vm.config.inputFolder) { _, _ in
    vm.invalidateCachedDocumentsIfInputChanged()
}
```

**Pravidlo:** každá editovatelná konfigurace má `.onChange` hook, který volá `persistAll` nebo `persistAllDebounced`. Žádný stav není „forgotten" po restartu.

---

## 15. Capability predikáty (`canX` pattern)

Disabled stav tlačítek nikdy neřeší view – vždy computed property na view modelu:

| Predikát | Kdy true |
|---|---|
| `canVerifyServer` | `hasSelectedServer` |
| `canLoadPrompts` | `hasPromptFolder` |
| `canRunPreprocessing` | `hasInputFolder` |
| `canRunExtraction` | vstup + výstup + server + inference model + prompt |
| `canRunAll` | alias pro `canRunExtraction` |
| `canOpenOutput` | `hasOutputFolder` |

Pod nimi hierarchie atomických `hasX` (hasInputFolder, hasOutputFolder, hasPromptFolder, hasInferenceModel, hasPrompt, hasSelectedServer).

**Pravidlo parity s runtime guardy:** každý runtime `guard` uvnitř `performX` (který by vedl k `.notStarted`) **musí mít svůj pár v `canX` predikátu**. Jinak tlačítko vypadá aktivní, uživatel klikne, a jediná reakce je změna textu ve statusbaru – to uživatel snadno přehlédne a dojde k dojmu „tlačítko nefunguje".

### 15.1 Missing-hint pattern (tooltip na disabled tlačítku)

Pro každou sadu requirementů má viewmodel paralelní computed property, která vrátí **seznam chybějících položek jako text** – použije se jako `.help(...)` tooltip na akčním tlačítku v toolbaru:

```swift
var missingRequirementsHint: String? {
    var missing: [String] = []
    if !hasInputFolder     { missing.append("vstupní složka") }
    if !hasOutputFolder    { missing.append("výstupní složka") }
    if !hasSelectedServer  { missing.append("server (Base URL)") }
    if !hasInferenceModel  { missing.append("inference model") }
    if !hasPrompt          { missing.append("prompt") }
    guard !missing.isEmpty else { return nil }
    return "Chybí: \(missing.joined(separator: ", "))"
}
```

A v toolbar tlačítku „Spustit":

```swift
Button { Task { await vm.runAll() } } label: {
    Label("Spustit", systemImage: "play.fill")
}
.disabled(!vm.canRunAll)
.help(vm.missingRequirementsHint
      ?? "Spustí kompletní pipeline: předzpracování + extrakci (Cmd+R)")
```

**Dvojí tooltip:**
- **Enabled** → popis akce + zkratka („Spustí kompletní pipeline (Cmd+R)").
- **Disabled** → seznam chybějících položek („Chybí: server, prompt").

macOS tooltip funguje i na disabled tlačítkách – uživatel najede myší a okamžitě ví, co doplnit.

---

## 16. State machine – Run/Stop v toolbaru

```
         ┌─────────────────────────────┐
         │  IDLE                        │
         │  toolbar: [Spustit (play)]  │
         │  body:    [Průběh idle]     │
         │           [Log]              │
         └──────┬───────────────────────┘
                │ Cmd+R / toolbar click
                ▼
         ┌─────────────────────────────┐
         │  RUNNING                     │
         │  toolbar: [Přerušit (stop)] │
         │  body:    [Průběh active]   │
         │           [Log]              │
         └──────┬───────────────────────┘
                │ finish / cancel / fail
                ▼
         ┌─────────────────────────────┐
         │  COMPLETED                   │
         │  toolbar: [Spustit] (zpět)   │
         │  body:    [Completion       │
         │            banner: Hotovo|  │
         │            Přerušeno|Selhalo] │
         │           [Průběh finished] │
         └──────┬───────────────────────┘
                │ click "Potvrdit" v banneru
                │ → acknowledgeCompletion()
                ▼
              IDLE
```

Output (toolbar) a Help (toolbar) jsou vždy přítomné, bez ohledu na stav. Předzpracování a Extrakce jsou v menu (Cmd+Shift+P / Cmd+Shift+E), nikoli v body.

---

## 17. State machine – Verify server

```
   Neověřeno                Ověřeno
   ─────────                ────────
   blue .bordered           green .bordered
   "Ověřit"                 "Ověřeno"
   checkmark.seal           checkmark.seal.fill
         │                       │
         │  verifyServer() OK   │
         └──────────────────────▶│
                                 │
         ◀────── change URL ─────┤
         ◀────── change API key ─┤
         ◀────── change server ──┘
         (invalidateServerVerification)
```

Po přechodu mezi LM Studio/MLX je stav `Neověřeno` záměrný. Model pickery jsou vyčištěné, dokud uživatel znovu nespustí `verifyServer()` a aplikace nenačte nový seznam modelů.

U backendů bez LM Studio `/api/v0/models` status po ověření obsahuje `kontext ručně`; uživatel pak nastaví Kontext modelu **v Settings → Výkon**.

---

## 18. State machine – Folder row

```
   Nevybráno                       Vybráno
   ─────────                       ───────
   ikona vlevo:  secondary         ikona vlevo:  green
   path display: "—" .tertiary     path display: "/full/path" .primary
   tlačítko:     blue "Vybrat"     tlačítko:     blue "Změnit"
         │                              │
         │  chooseXFolder() OK / drop   │
         └──────────────────────────────▶│
         ◀──── path cleared ─────────────┘
```

Stav nese **ikona** (zelená vs. secondary) a **path text** (cesta vs. em-dash). Tlačítko zůstává v jednotné modré barvě s konstantní pozicí — mění jen label (Vybrat → Změnit). To řeší původní matení uživatelů, kteří „Vybráno" tlačítko mylně považovali za stavový badge a neklikali na něj při změně cesty.

---

## 19. Settings – Stepper rozsahy a kroky

Žijí v [Views/SettingsView.swift](../SpiceHarvester/Views/SettingsView.swift), tab Výkon. Formulář je rozdělený do sekcí **Souběžnost** a **Model a HTTP**.

| Parametr | Min | Max | Step |
|---|---|---|---|
| `maxConcurrentInference` | 1 | 16 | 1 |
| `maxConcurrentPDFWorkers` | 1 | 16 | 1 |
| `throttleDelayMs` | 0 | 2000 | 50 |
| `modelContextTokens` | 4 096 | 1 048 576 | 4 096 (zobr. jako k tokenů) |
| `requestTimeoutSeconds` | 60 | 3 600 | 60 |

Použity v `Stepper(value: …) { LabeledContent("Popis") { Text(formatted).monospacedDigit() } }`. Každý má `.help(...)` s vysvětlením, co se stane na krajích rozsahu.

---

## 20. ProgressView varianty

| Kontext | Velikost | Tint |
|---|---|---|
| Toolbar status indicator | `.small` | default |
| Karta Průběh (active phase) | default | `.blue` |
| Status bar | `.mini` | default |

V hlavním okně už **není** žádný „Pracuji" prominent button – Run/Stop žije v toolbaru a kartě Průběh, status indikátor v toolbaru pokrývá generic „aplikace teď něco dělá" indikaci.

---

## 21. LabelStyle konvence

- **Default** (`.titleAndIcon`, implicit) – většina tlačítek.
- **`.labelsHidden()`** – pickery, kde caption je nad nimi jako vlastní `Text`, nebo kde je picker uvnitř Form Sectionu (Settings).
- Toolbar `Label(...)` má auto-rendering – text se na úzkém okně skryje a zůstane jen ikona (NSToolbar default).

---

## 22. Text truncation a lineLimit

| Kontext | Chování |
|---|---|
| `statusText` ve status baru | `lineLimit(1)` + `truncationMode(.middle)` (cesty se ořízají uprostřed) |
| Folder path display | `lineLimit(1)` + `truncationMode(.middle)` + plná cesta v `.help(...)` tooltipu |
| Conflict banner / completion banner message | `fixedSize(horizontal: false, vertical: true)` – wrapuje libovolně na výšku |
| Mode caption | `fixedSize(horizontal: false, vertical: true)` – 1–2 řádky podle režimu |
| Log | bez limitu, monospace, auto-scroll |
| Prompt TextEditor | `minHeight 160`, `maxHeight 280` – rozšiřitelný, ale nemaže zbytek UI |

---

## 23. Accessibility konvence

- Každá ikona **bez textového labelu** má `.accessibilityLabel` (+/− server, status tečka, „Obnovit" log).
- Každé tlačítko s netriviální funkcí má `.help` (tooltip). Text je česky, věcný, často s klávesovou zkratkou.
- Status bar i toolbar status hlásí VoiceOveru **plnou větu**: „Stav: {statusText}", ne jen „statusText".
- Při běhu (`isRunning`) je toolbar indikátor `ProgressView(.small)` s textem; v idle je zelená tečka 9 pt s textem.

---

## 24. Okno – custom behavior (`SHAppDelegate`)

SwiftUI `.defaultSize` se aplikuje jen **první spuštění**. `SHAppDelegate` přes `NSApplicationDelegateAdaptor` při každém launchi:

1. Počká jeden run-loop tick (`DispatchQueue.main.async`) – SwiftUI okno se vytváří **po** `applicationDidFinishLaunching`.
2. Najde hlavní okno (`NSApp.mainWindow` → fallback `windows.first(width > 300)` → fallback `windows.first`).
3. Roztáhne na **plnou výšku** `screen.visibleFrame` (bez menu baru a Docku), aby se na velkém monitoru při startu zbytečně neobjevil vertikální scrollbar.
4. Šířka: pokud `visible.width >= 1440` a `visible.height >= 1100`, použije `largePreferredWidth 1320 pt` capped `visible.width`; jinak použije max aktuální šířky a `compactPreferredWidth 1200 pt`, také capped `visible.width`.
5. Horizontálně vycentruje, bottom-align (pracuje s Cocoa souřadným systémem – Y roste nahoru).

**Při refaktoringu nepřepisovat v SwiftUI** – použít tento AppDelegate jako single source of truth pro velikost okna. Aplikuje se jen na hlavní `WindowGroup`; Settings okno má vlastní velikost (620 × 540, viz §1).

---

## 25. Persistence a session-scoped flags

Některé flagy **nežijí napříč restarty** záměrně:

| Flag | Scope | Důvod |
|---|---|---|
| `isSelectedServerVerified` | session only | Server může mezitím spadnout – verify je ephemeral |
| `pendingConflict` | view-local `@State` | Dialog je momentální interakce |
| `lastCompletion` | session only | Uživatel ji acknowledgne klikem v completion banneru, pak mizí |
| `logText` | session only | Nový běh = čistý log |
| `progressState`, `benchmark` | per-run | Reset na start nového běhu |
| `showHelp` | App-level `@State` | Sheet visibility, sdílená mezi toolbar buttonem a Help menu |

Všechno ostatní v `SHAppConfig` + `servers` je **perzistentní** přes `persistAll` / `persistAllDebounced`.

---

## 26. Checklist při přidávání nového UI prvku

Při refaktoringu nebo přidání nového pole/tlačítka:

- [ ] Patří prvek do hlavního okna, nebo do Settings? **Pokud uživatel hodnotu nastaví ≤ 1× za session → Settings.**
- [ ] Je v sekci sémanticky patřící `GlassCard` (hlavní okno) nebo Form Sectionu (Settings)?
- [ ] Má `Label(text, systemImage:)` s SF Symbolem odpovídající sémantice?
- [ ] Je labeling česky?
- [ ] Má nezřejmé tlačítko `.help` tooltip? Obsahuje klávesovou zkratku, pokud existuje?
- [ ] Má ikona bez textu `.accessibilityLabel`?
- [ ] Nový perzistentní field → `.onChange { persistAll() }` nebo `persistAllDebounced` (debounced pro keystroke-driven, immediate pro pickery/togglery)?
- [ ] Pokud field invaliduje jiný stav (verify, cache) → volá se `invalidateX()` ze setteru?
- [ ] Nové tlačítko s podmínkou → nový `canX` predikát na view modelu?
- [ ] **Každý runtime `guard` uvnitř `performX` má pár v `canX`?** (bez toho dochází k tichému `.notStarted` a zdání „tlačítko nefunguje")
- [ ] Tlačítko s více requirementy → `missingXHint: String?` property + `.help(...)` tooltip dle §15.1?
- [ ] Nová klávesová zkratka → registrovaná v `.commands { CommandGroup(...) }` (App scene), ne `.keyboardShortcut` na rozházených buttonech?
- [ ] Používá tint z palety (`.blue` primary, `.green` OK, `.red` stop), ne ad-hoc barvu?
- [ ] Prázdný stav = em-dash / text placeholder, ne nula / skrytý prvek?
- [ ] Šířka kontrolky ladí s existujícími tokeny (§12) nebo flexí pod limitem sloupce?
- [ ] Spacing 6/8/10/14 pt (§7), corner radius 6/8/10 pt?
- [ ] Destruktivní akce → `.confirmationDialog` nebo `role: .destructive` v Settings, ne ad-hoc tlačítko v hlavním okně?
- [ ] Stavový flip (stejný element, jiný vzhled) > mizející element?
- [ ] Nový sheet → řídí se §27 (thinMaterial lišty, X v headeru, defaultAction v patičce)?

---

## 27. Modální sheet – vzor (Help sheet)

Šablona pro každý další modální dialog v aplikaci. Zdroj: [Views/HelpSheet.swift](../SpiceHarvester/Views/HelpSheet.swift).

### 27.1 Struktura

```
┌─────────────────────────────────────────┐
│ [icon] Titulek                   [X]    │  ← .thinMaterial header
├─────────────────────────────────────────┤
│                                         │
│  ScrollView se sekcemi                  │
│                                         │
├─────────────────────────────────────────┤
│                            [Zavřít]     │  ← .thinMaterial footer
└─────────────────────────────────────────┘
```

3 pevné části (`VStack(spacing: 0)`):

| Část | Styl |
|---|---|
| **Header bar** | `HStack` s ikonou + titulkem (`.title2.weight(.semibold)`) + `Spacer` + close tlačítko `xmark.circle.fill` `.title3` `.secondary` `.borderless`. Padding 20, `.thinMaterial` bg. Pod tím `Divider()`. |
| **Content** | `ScrollView` s `VStack(alignment: .leading, spacing: 24)`, padding 24, `frame(maxWidth: .infinity, alignment: .leading)`. Obsah sekcí přes helper funkce (§27.3). |
| **Footer** | `HStack` s `Spacer` + prominent „Zavřít" (`.borderedProminent` blue, `.keyboardShortcut(.defaultAction)`). Padding 16, `.thinMaterial` bg. Nad tím `Divider()`. |

### 27.2 Frame

```swift
.frame(minWidth: 640, idealWidth: 720, maxWidth: 900,
       minHeight: 600, idealHeight: 780, maxHeight: .infinity)
```

- **min 640 × 600** – vždy čitelné, není to miniokno.
- **ideal 720 × 780** – nativní velikost, vejde se obsah help sheetu bez scrollu.
- **max 900** šířky – nad to už je to spíš druhé okno než dialog.

### 27.3 Helper funkce (pro obsah)

| Helper | Použití | Podporuje markdown |
|---|---|---|
| `section(icon:title:content:)` | Sekce s modrou ikonou + nadpis `.title3.weight(.semibold)` + obsah s padding-leading 4 | — |
| `paragraph(_ text:)` | Volný odstavec `.body`, `fixedSize(vertical: true)` | ✅ `**bold**` |
| `step(_ number:_ text:)` | Očíslovaný bod, modrá cifra `monospacedDigit`, width 22 pt right-aligned | ✅ |
| `bullet(_ text:)` | Bullet point, malá kolečková ikona 5 pt, `.secondary` | ✅ |
| `mode(symbol:name:desc:)` | Název režimu (bold) + popis (`.secondary`) s SF Symbolem vlevo | — |

**Markdown** přes `Text(.init(text))` → `LocalizedStringKey` parser. Umožňuje `**bold**`, `*italic*`, ``` `code` ``` a `[links](…)` přímo v obsahu.

### 27.4 Spouštění

- Stav `showHelp` žije na úrovni App scene (`@State`) — sdílen mezi toolbar buttonem (`Binding`) a `CommandGroup(replacing: .help)` položkou.
- `.sheet(isPresented: $showHelp) { HelpSheet(dismiss: { showHelp = false }) }` aplikován na **vnější VStack** v `ContentView.body`.

### 27.5 Kdy použít tento vzor vs. jiné modální typy

| Kontext | Mechanismus |
|---|---|
| Rozsáhlejší help / onboarding (≥ 2 obrazovky textu) | **Sheet dle §27** |
| Přetrvalá nastavení, která uživatel mění zřídka | **Settings Scene** (Cmd+,, viz §1) |
| Jednorázové potvrzení destruktivní akce | `.confirmationDialog` (viz §5.6) |
| Výběr souboru/složky | `NSOpenPanel` z AppKitu (folder rows) |
| Krátká chyba / info hláška | Inline banner v `GlassCard` (viz §5.6) |
| Rychlé info u tlačítka / stepperu | `.help(...)` tooltip |

**Pravidlo:** sheet je drahý – vyžaduje interakci uživatele se zavřením. Settings Scene je levnější (nativní macOS okno, Cmd+W ho zavře). Pro pokročilé hodnoty volit **Settings**, ne sheet.

---

## 28. Compact Glass – designový jazyk

Aplikace používá **Compact Glass** – density-first varianta native macOS glass designu. Optimalizovaná pro „power user dashboard", kde je důležité vidět celou pipeline na jedné obrazovce.

### 28.1 Pilíře

1. **Density > whitespace.** Raději 12 pt padding než 18, raději 10 pt spacing než 16. Pokud se obsah vejde bez dýchání, vejde se i s ním – jen není vidět najednou.
2. **Tlumená hierarchie.** Nadpisy karet jsou `.secondary` šedé (ne bold černé) – obsah karty musí být nejsytější prvek. Karta je **kontejner, ne headline**.
3. **Jemné materiály bez stínu.** `.regularMaterial` pro karty, `.thinMaterial` pro lišty. **Žádný drop shadow** — karty se odlišují jen rozdílem materiálu a tenkým strokem. Stínování několika kartami nad sebou na window-sized gradientu šuměl bez přidaných informací.
4. **Neinvestujeme do kroucení.** Žádné zaoblení větší než 10 pt na kartě, žádné glow effect, žádný blur nad rámec systémových materiálů. Glass není dekorace, glass je **substrate pro obsah**.
5. **Akce jsou nejsytější.** Tlačítka (`.bordered`, prominent v toolbaru) i barevné tinty (green OK, red stop) nesou **plný kontrast** – aby se jednoznačně oddělily od tlumeného pozadí karty.
6. **Nativní macOS první.** Toolbar místo header bannerů, Settings Scene místo vlastního „Předvolby" okna, `.commands` místo ad-hoc keyboard listenerů. Glass design respektuje OS chrome.

### 28.2 Dvousloupcový layout (důvod)

Původní jednosloupcové uspořádání s vertikálním scrollem nutilo uživatele scrollovat mezi konfigurací a runtime stavem. Pro „dlouhý běh, na který se chci dívat" to znamenalo, že progress + log byly trvale pod skladem konfigurace.

`HSplitView` rozdělí pozornost správně:
- **Vlevo:** věci, které uživatel mění před runem (Složky, Server, Prompt). Mají vlastní `ScrollView` — konfigurace je vyšší.
- **Vpravo:** věci, na které se uživatel kouká během runu (Průběh, Log). Žádný outer scroll — log nese zbytek vertikální výšky.

Window toolbar drží Run/Stop nad oběma sloupci, takže akce není vázaná na konkrétní část body.

### 28.3 Co žije v Settings (Cmd+,)

Pokročilá nastavení byla přesunuta z hlavního okna do Settings Scene. Heuristika: **uživatel to mění ≤ 1× za session, nepotřebuje to vidět při běhu.**

| Před (v hlavním okně) | Teď (Settings tab) |
|---|---|
| Stepper `Inference workers` | Výkon |
| Stepper `PDF/OCR workers` | Výkon |
| Stepper `Throttle delay` | Výkon |
| Stepper `Kontext modelu` | Výkon |
| Stepper `Timeout` | Výkon |
| Picker `OCR backend` (segmented) | OCR |
| Toggle `Ignorovat cache LLM odpovědí` | Cache |
| Tlačítko `Vyčistit cache` (vedle „Spustit") | Cache (`role: .destructive`, oddálené od Run) |

Settings okno používá vlastní tab selector místo systémového `TabView` tab stripu. Důvod je praktický: vybraný systémový tab měl ve světlém režimu bílý text na světlém pozadí. Vlastní selector drží vybraný stav přes `@State selectedTab`, explicitně barví text `.primary` / `.secondary` a switchuje obsah přes `selectedTabContent`.

Hlavní okno se zúžilo o ≈ 4 řádky vertikálně a ztratilo 8 ovládacích prvků, které původně otestoval každý nový uživatel a víckrát už ne.

### 28.4 Token migrace (referenčně)

Hlavní spacing/typografie tokeny:

| Token | Hodnota |
|---|---|
| Card padding | 12 |
| Card corner radius | 10 |
| Card shadow | **0** (odstraněn) |
| Card header font | `.subheadline.semibold` + secondary |
| Body outer padding (sloupec) | 14 |
| Cards-to-cards spacing | 10 |
| Row spacing (v kartě) | 6 – 10 |
| Logo | 36 × 36 |
| App title | `.title2.bold` |
| Subtitle | `.caption` |
| Folder row label width | 130 |
| Prompt editor min/max výška | 160 / 280 |
| Prompt editor font | 12 pt mono |
| Log min výška | 200 |
| Log font | 10.5 pt mono |
| Status bar font | `.caption` |
| Status bar dot | **10 pt** (zvětšeno z 7 pt — accessibility) |
| Min window | 980 × 680 |
| Preferred width | 1200 compact / 1320 large screen |

### 28.5 Kdy se od Compact Glass odchýlit

- **Help sheet / onboarding** – modální obsah má jiný „mental model", může použít prostornější hierarchii (`.title2.semibold` nadpisy, `padding(24)`). Viz §27.
- **Settings Scene** – nativní macOS Form `.grouped`, ne Compact Glass. Form je tu standard a uživatel ho zná z System Settings.
- **Chybový / success state** – completion banner využívá `tint.opacity(0.10)` fill — tady je důraz podřízen jasnosti stavu, ne density.
- **Destruktivní potvrzení** – `.confirmationDialog` je systémový, nelze ho nacpat do kompaktního rámu.

Všechno ostatní v hlavním okně se drží Compact Glass.

### 28.6 Anti-patterns (nezavádět)

- ❌ Karta bez `GlassCard` wrapperu (ztráta konzistence materiálu).
- ❌ Drop shadow na hlavní kartě (Compact Glass je flat — odlišení nese material + stroke).
- ❌ Vlastní `cornerRadius` větší než 10 pt na hlavní kartě.
- ❌ `.headline` nebo `.title*` jako nadpis karty (přebije obsah – secondary sub-heading je záměr).
- ❌ Použití `.ultraThinMaterial` nebo `.thickMaterial` – aplikace má **dvojstupňový blur** (regular / thin), třetí stupeň rozbíjí konzistenci.
- ❌ `.padding(20)` nebo větší uvnitř karty – porušuje density pilíř.
- ❌ Explicit `Color.white` / `Color.black` – vždy sémantické (`.primary`, `.secondary`, `.tertiary`, `.quinary`, accent barvy).
- ❌ Animované gradienty, particle effects, hover glow – glass je statický substrate.
- ❌ Ad-hoc „Předvolby" okno místo `Settings { … }` Scene – ztrácí Cmd+, integraci a System Settings vzhled.
- ❌ Run/Stop button v body místo toolbaru – ztrácí trvalou viditelnost při scrollu konfigurací.
- ❌ Performance steppery v hlavním okně – patří do Settings, brání density ostatních karet.
