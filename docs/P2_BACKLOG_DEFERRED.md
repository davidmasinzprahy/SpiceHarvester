# P2 backlog — odložené položky s implementačními poznámkami

Tento soubor dokumentuje P2 položky z [auditu](../README.md), které **vědomě
odkládáme** mimo aktuální implementační rozsah. Pro každou je sepsaný plán
implementace, scope a očekávaný čas. Slouží jako vstup pro budoucí ticket.

## Status (aktuální stav)

| Položka | Stav |
|---|---|
| Lokalizace (String Catalog) | ✅ Hotovo |
| AppIntents pro Shortcuts | ✅ Hotovo |
| Save / Load Project commands (interim za DocumentGroup) | ✅ Hotovo |
| Multi-window (scratch WindowGroup, Cmd+Shift+N) | ✅ Hotovo (minimal) |
| Quick Look provider source | 🟡 Source ready, target chybí |
| Quick Look Preview Extension target | 📋 Vyžaduje Xcode IDE (#1 níže) |
| Plný DocumentGroup s file-based persistencí | 📋 3-day refactor (#3 níže) |
| iCloud Drive sync | 📋 Vyžaduje Apple Dev account (#2 níže) |

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

## 2. iCloud Drive sync

### Co a proč
Aktuálně všechny cesty (input/output/cache/prompty) jsou lokální. Pro
multi-device workflow by se hodilo, aby `prompty/` a `output/` mohly žít
v iCloud Drive a synchronizovat se přes všechny Mac uživatele.

### Proč odloženo
Vyžaduje **změnu entitlements + container ID + provisioning**:
- `com.apple.developer.icloud-container-identifiers` v `.entitlements`
- iCloud capability v Apple Developer accountu
- `NSUbiquitousContainerIdentifier` v Info.plist
- File coordination (NSFileCoordinator) pro každé file IO

Bez Apple Developer účtu (signed app) iCloud nelze testovat. Build s
`Sign to Run Locally` (aktuální stav) iCloud entitlements ignoruje.

### Implementační kroky
1. V Apple Developer portálu: vytvořit iCloud container `iCloud.DavidMasin.SpiceHarvester`.
2. V Xcode capabilities: zapnout iCloud → CloudKit + Document storage.
3. Update obou `.entitlements` souborů:
   ```xml
   <key>com.apple.developer.icloud-container-identifiers</key>
   <array><string>iCloud.DavidMasin.SpiceHarvester</string></array>
   <key>com.apple.developer.icloud-services</key>
   <array><string>CloudDocuments</string></array>
   ```
4. V `SHFileScanService` a `SHCacheManager`: použít
   `FileManager.default.url(forUbiquityContainerIdentifier:)` pro výchozí
   cesty, fallback na local kontejner.
5. UI: v Settings přidat toggle "Použít iCloud Drive pro výstup / prompty"
   s explicit opt-in (kvůli ochraně dat).
6. File coordination wrap v každém read/write.

### Risk
- iCloud sync má eventual consistency — concurrent edit z dvou Maců =
  conflict. Potřeba conflict UI.
- File coordination je verbose, vyžaduje refactor existujícího IO.
- App Sandbox + iCloud kombinace má edge cases (security-scoped
  bookmarky vs ubiquity URL).

### Odhad
- Capability + entitlements + Info.plist: **1 h**
- File path migration + coordination: **1–2 dny**
- Conflict handling: **1 den**
- Cross-device QA: **0.5 dne**
- Celkem ~**3–4 pracovní dny**.

---

## 3. Multi-window support přes DocumentGroup

### Co a proč
Aktuálně `WindowGroup` = single window. Pro power-usera s 3 různými
"projekty" (různé prompty + různá vstupní data + různé modely) jediná
možnost je ručně přepínat config nebo spustit více instancí přes hack.

`DocumentGroup` by transformoval app na document-based:
- Cmd+N = nový projekt
- Cmd+O / File → Open Recent
- Per-window viewmodel
- iCloud sync zdarma (přes UIDocument-equivalent NSDocument na macOS)
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
- Žádný iCloud Drive auto-sync
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
3. **iCloud Drive** je smysluplný jen *po* DocumentGroup; bez document modelu
   sync neřeší nic. Pořadí: DocumentGroup → iCloud → Continuity.

---

## Související P2 položky **už hotové**

| Položka | Stav | Commit |
|---|---|---|
| Lokalizace (String Catalog) | ✅ Hotovo | viz `Localizable.xcstrings` |
| AppIntents pro Shortcuts | ✅ Hotovo | viz `AppIntents/SHAppIntents.swift` |
| Settings search | ✅ Hotovo | předchozí commit |
| Dynamic Type clamp | ✅ Hotovo | předchozí commit |
| NSTextView log + severity coloring | ✅ Hotovo | předchozí commit |
