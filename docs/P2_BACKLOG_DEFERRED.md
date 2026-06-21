# P2 backlog — odložené položky s implementačními poznámkami

Tento soubor dokumentuje P2 položky z [auditu](../README.md), které **vědomě
odkládáme** mimo aktuální implementační rozsah. Pro každou je sepsaný plán
implementace, scope a očekávaný čas. Slouží jako vstup pro budoucí ticket.

## Status (aktuální stav)

| Položka | Stav |
|---|---|
| Lokalizace (String Catalog) | ✅ Hotovo |
| AppIntents pro Shortcuts | ✅ Hotovo + parametry + wait + targetFolder + tab activation + structured return |
| Save / Load Project commands (interim za DocumentGroup) | ✅ Hotovo |
| Multi-window (scratch WindowGroup, Cmd+Shift+N) | ✅ Hotovo + per-tab title/server + collision detection + Help window scene |
| Quick Look provider — zdroj + UTI/export | ✅ Zdroj `SHQuickLookPreview.swift` (guarded) + UTI/export `.spice-result.json` hotové; **Xcode extension target chybí** (#1 níže) |
| Plný DocumentGroup s file-based persistencí | 📋 3-day refactor (#2 níže) |
| API key migrace na Keychain | ✅ Hotovo — `SHKeychain` + `SHServerRegistryStore`, `apiKey` mimo Codable, jednorázová migrace plaintextu |

## 1. Quick Look provider pro výstupní JSON

### Co a proč
Spice Harvester ukládá per-document `*.json` a `*_raw.json` do výstupní složky.
Ve Finderu Quick Look (Space-press) momentálně ukáže raw JSON text. Vlastní
Quick Look provider by mohl renderovat hezky strukturovaný náhled
(patient_name, lab_values jako tabulka, atd.).

### Stav: source ready, target chybí

Provider zdroj je už checkin za `#if QUICK_LOOK_EXTENSION` guard v
[SHQuickLookPreview.swift](../SpiceHarvester/QuickLook/SHQuickLookPreview.swift).
Renderuje strukturovanou HTML tabulku z canonického SHExtractionResult JSONu,
escape-safe pro source_file (XSS guard), dark-mode aware. Stačí přidat
samotný Xcode target a soubor do něj zařadit.

### Proč odloženo
**Vyžaduje samostatný Xcode target** — `Quick Look Preview Extension`. To je
nový bundle s vlastním Info.plist, entitlements a UTI registrací. Aktuální
projekt používá `PBXFileSystemSynchronizedRootGroup` pro main app; přidání
extension targetu je zásah do `project.pbxproj`, který se nedá udělat
incrementálně bez Xcode IDE.

### Implementační kroky (až k tomu dojde)
1. V Xcode: **File → New → Target → Quick Look Preview Extension** (macOS).
   Zvolit jméno `SpiceHarvesterQuickLook`.
2. Definovat custom UTI v hlavní app `Info.plist` pod `UTExportedTypeDeclarations`:
   ```xml
   <key>UTExportedTypeDeclarations</key>
   <array>
     <dict>
       <key>UTTypeIdentifier</key><string>DavidMasin.SpiceHarvester.result</string>
       <key>UTTypeConformsTo</key>
       <array><string>public.json</string></array>
       <key>UTTypeTagSpecification</key>
       <dict><key>public.filename-extension</key><array><string>spice-result.json</string></array></dict>
     </dict>
   </array>
   ```
3. Aktualizovat `SHExportService` — výstupní soubory pojmenovávat
   `{name}.spice-result.json` místo `{name}.json`, aby se UTI matchoval.
4. V extension targetu napsat `QLPreviewProvider` subclass, která načte JSON
   a vyrenderuje SwiftUI view s tabulkou.

### Risk
- Extension nemá síť ani filesystem mimo přidělené sandbox. Decode JSON,
  render. Nic složitého, ale **dodatečné code-signing pravidlo**.

### Odhad
- Setup target + UTI: **2 h**
- Provider implementace: **3–5 h**
- QA na různých výstupech: **2 h**
- Celkem ~**1 pracovní den**.

---

## 2. Multi-window support přes DocumentGroup

### Co a proč
Aktuálně `WindowGroup` = single window. Pro power-usera s 3 různými
"projekty" (různé prompty + různá vstupní data + různé modely) jediná
možnost je ručně přepínat config nebo spustit více instancí přes hack.

`DocumentGroup` by transformoval app na document-based:
- Cmd+N = nový projekt
- Cmd+O / File → Open Recent
- Per-window viewmodel
- Recents v menu, drag-onto-icon, etc.

### Proč odloženo
**Vyžaduje strukturní refactor `SHAppViewModel`**:
- Aktuálně je vm vytvořen v `App.body` jako `@State`
- DocumentGroup vyžaduje per-document content type (`FileDocument` nebo `ReferenceFileDocument`)
- vm musí být buďto sdílený (server registry, app-level prefs) NEBO per-doc
- Persistence flow se přepíše: persistAll → encode do FileDocument

### Implementační kroky
1. Definovat `SHProjectDocument: FileDocument`:
   ```swift
   struct SHProjectDocument: FileDocument {
       static var readableContentTypes: [UTType] = [.spiceharvester]
       var config: SHAppConfig
       var promptHistory: [String]
       
       init(configuration: ReadConfiguration) throws {
           let data = configuration.file.regularFileContents ?? Data()
           let payload = try JSONDecoder().decode(SHProjectPayload.self, from: data)
           self.config = payload.config
           self.promptHistory = payload.promptHistory
       }
       func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
           let payload = SHProjectPayload(config: config, promptHistory: promptHistory)
           let data = try JSONEncoder().encode(payload)
           return FileWrapper(regularFileWithContents: data)
       }
   }
   ```
2. Definovat UTI `DavidMasin.SpiceHarvester.project` v Info.plist
   (`UTExportedTypeDeclarations`, conforms `public.json`, extension `.spiceharvester`).
3. Rozdělit `SHAppViewModel` na:
   - `SHGlobalState` (server registry, app prefs) — singleton, šaháno v init
   - `SHDocumentViewModel` (per-document config, runtime state) — created from FileDocument
4. V `SpiceHarvesterApp.body`:
   ```swift
   DocumentGroup(newDocument: SHProjectDocument()) { file in
       ContentView(document: file.$document, global: globalState, showHelp: $showHelp)
   }
   ```
5. Migrace existujících uživatelů: při prvním otevření po update převést
   stávající persistované konfigurace do "Default Project.spiceharvester"
   v `~/Documents/Spice Harvester/`.

### Risk
- **Velký refactor** všech viewmodel-touching call sites (~30+ míst).
- **Migration path** pro existující uživatele s persistovaným config bez
  document souboru.
- **Server registry** musí zůstat globální (login credentials per-doc je
  out of scope).

### Aktuální interim řešení (≈ 80 % užitku)

Místo plné DocumentGroup migrace je nyní implementováno:

1. **Save / Load Project** přes File menu (Cmd+Shift+S / Cmd+O) — JSON
   snapshot folderů, modelů, promptu, mode. Server registry intentionally
   not included (kept globally). Viz `SHProjectSnapshot` v `SHAppViewModel.swift`.
2. **Multi-window** přes `WindowGroup(id: "scratch", for: UUID.self)` —
   Cmd+Shift+N otevře novou scratch window s vlastním view-modelem.
   Scratch persistence mode: skipuje `configStore.save` (nepřepisuje
   primary window's slot), ale server registry sdílí. Pro persistování
   scratch konfigu uživatel použije Uložit projekt jako…

**Co interim NEzvládá oproti plné DocumentGroup:**
- Žádný File → Open Recent (každé otevření přes panel)
- Žádný drag .spiceharvester soubor na app icon
- Migrace existing UserDefaults config nepotřebuje žádnou — primary window
  načítá UserDefaults dál jako vždy

### Odhad
- Refactor SHAppViewModel split: **1 den**
- DocumentGroup integration: **0.5 dne**
- Migration logic: **0.5 dne**
- QA na multi-window scénářích: **1 den**
- Celkem ~**3 pracovní dny**.

---

## Priority

1. **Quick Look provider** je nejviditelnější uživatelská přidaná hodnota
   pro nejméně práce (~1 den). Kandidát na další iteraci.
2. **DocumentGroup** je největší architectural shift — pokud je multi-project
   workflow reálná uživatelská potřeba, tohle je správný čas.

---

## Související P2 položky **už hotové**

| Položka | Stav | Commit |
|---|---|---|
| Lokalizace (String Catalog) | ✅ Hotovo | viz `Localizable.xcstrings` |
| AppIntents pro Shortcuts | ✅ Hotovo + job semantics | `RunSpiceHarvesterIntent` má `@Parameter mode` + `@Parameter promptName`, čeká na completion přes `runDidComplete`, vrací `ReturnsValue<String>` (cesta k `results.csv`); viz `AppIntents/SHAppIntents.swift` |
| Settings search | ✅ Hotovo | předchozí commit |
| Dynamic Type clamp | ✅ Hotovo | předchozí commit |
| NSTextView log + severity coloring | ✅ Hotovo | předchozí commit |
| Quick Look Preview Extension target | 📋 **Nehotovo** | Target v `project.pbxproj` neexistuje (jen 3 targety: app/Tests/UITests). Kanonický zdroj `SpiceHarvester/QuickLook/SHQuickLookPreview.swift` je za `#if QUICK_LOOK_EXTENSION` guardem, takže se zatím nikam nekompiluje. Viz #1. (Dřívější osiřelý duplikát `SpiceHarvesterQuickLook/` mimo projekt byl smazán.) |
| UTI + Export `.spice-result.json` + Import | ✅ Hotovo | `Info.plist` `CFBundleDocumentTypes` + `UTExportedTypeDeclarations`, `SHExportService` per-file `*.spice-result.json` naming + `SHAppViewModel.openSpiceResultFile` + `SHAppDelegate.application(_:open:)` bridge |
| API klíče v Keychainu | ✅ Hotovo | `SHKeychain` (generic password, per-server UUID) za protokolem `SHAPIKeyStoring`; `SHServerConfig.apiKey` mimo `Codable`; `SHServerRegistryStore` hydratuje/ukládá klíče zvlášť, jednorázová migrace plaintextu z UserDefaults, úklid při odebrání serveru. Testy v `SHServerRegistryTests`. |
| Resizovatelné okno Předvoleb | ✅ Hotovo | `SettingsWindowConfigurator` napojí Settings `NSWindow` na AppKit autosave (jako hlavní okno); frame je `min…max` místo pevné velikosti |

---

## Poznámka

Migrace API klíčů do Keychainu už je **hotová** (viz tabulka výše) — implementace
`SHKeychain` / `SHServerRegistryStore`. Tento soubor sleduje jen zbývající
odložené položky (#1 Quick Look target, #2 DocumentGroup).
