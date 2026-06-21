# Otevření projektu z Finderu (DocumentGroup #2 — varianta B)

## Cíl

Otevřít projektový soubor `*.spiceharvester.json` dvojklikem ve Finderu nebo
přetažením na ikonu aplikace. Zároveň opravit stejnou chybou postižený matching
pro `*.spice-result.json`.

## Kontext / proč ne plný DocumentGroup

Interim už pokrývá většinu užitku plného `DocumentGroup`:
- **Open Recent** — `recentProjectURLs` + menu „Otevřít nedávné" (`SpiceHarvesterApp.swift`).
- **Save/Load projektu** — `saveProjectAs` / `openProject` (soubory `*.spiceharvester.json`).
- **Multi-window** — scratch okna (Cmd+Shift+N) s vlastním view-modelem.

Jediná reálná mezera je otevření projektu z Finderu. Plný `DocumentGroup`
(rozbití 3108řádkového `SHAppViewModel`, přechod scény, migrace) by za vysoké
riziko přidal hlavně tuto jednu věc + nativní document lifecycle. Varianta B
zavře mezeru s minimem rizika a využije hotový interim.

## Nalezený bug (opravit v rámci B)

`SHAppDelegate.application(_:open:)` matchuje `url.pathExtension == "spice-result.json"`.
`URL.pathExtension` ale vrací jen poslední komponentu (`"json"`), takže podmínka je
**vždy nepravdivá** — stávající Finder-open pro `.spice-result.json` nikdy nesedne.
Oprava: matchovat přes `lastPathComponent.hasSuffix(...)`.

## Design

### 1. `SpiceHarvester/Info.plist`
- `UTExportedTypeDeclarations`: nový typ `DavidMasin.SpiceHarvester.project`
  - `UTTypeConformsTo` = `public.json`
  - `UTTypeTagSpecification` → `public.filename-extension` = `spiceharvester.json`
  - `UTTypeDescription` = „Spice Harvester Project"
- `CFBundleDocumentTypes`: nový záznam
  - `CFBundleTypeName` = „Spice Harvester Project"
  - `CFBundleTypeRole` = `Editor`, `LSHandlerRank` = `Owner`
  - `LSItemContentTypes` = `[DavidMasin.SpiceHarvester.project]`

Tím LaunchServices začne směrovat open eventy projektových souborů do aplikace.

### 2. `SHAppDelegate`
- Pure, testovatelná routovací funkce:
  ```swift
  enum SHOpenableFile { case project, result, unsupported }
  static func fileKind(for url: URL) -> SHOpenableFile {
      let name = url.lastPathComponent
      if name.hasSuffix(".spiceharvester.json") { return .project }
      if name.hasSuffix(".spice-result.json") { return .result }
      return .unsupported
  }
  ```
- `application(_:open:)` přepsat na `switch fileKind(for: url)`:
  - `.project` → guard `!vm.isRunning` (jinak friendly alert „nelze otevřít projekt během běhu"); `vm.openProject(at: url)` + `SHAppDelegate.handleOpenProjectOutcome(outcome)`
  - `.result` → `vm.openSpiceResultFile(url)`
  - `.unsupported` → ignorovat
- Zachovat stávající „app ještě nebyl spuštěn" alert, když `primaryViewModel == nil`.

### 3. Testy
Unit testy na `SHAppDelegate.fileKind(for:)`:
- `x.spiceharvester.json` → `.project`
- `x.spice-result.json` → `.result`
- `x.json` / `x.pdf` → `.unsupported`
- dvojitá přípona se nezamění (regrese na opravený bug).

## Ověření
- `xcodebuild build` + unit testy zelené.
- Manuální (uživatel): dvojklik na `*.spiceharvester.json` ve Finderu otevře projekt.

## Mimo rozsah
- Žádné rozbití `SHAppViewModel`, žádný přechod na `DocumentGroup`, žádný nativní
  document lifecycle (autosave/versions/modified-dot). Interim + tato integrace
  pokrývají praktickou potřebu.
