# Quick Look Preview Extension — design

## Cíl

Skenovatelné `*.spice-result.json` výsledky ve Finderu mají dnes Quick Look
(mezerník) jen jako raw JSON text. Cílem je přidat **Quick Look Preview Extension
target**, který renderuje strukturovaný HTML náhled (jméno pacienta, lab hodnoty,
diagnózy, …) z kanonického JSONu.

Zdroj náhledu (`SHQuickLookPreview.swift`) i UTI/export už existují; chybí jen
samotný Xcode extension target a jeho napojení do hlavní aplikace.

## Výchozí stav (ověřeno)

- Zdroj `SpiceHarvester/QuickLook/SHQuickLookPreview.swift` je **plně soběstačný**
  — parsuje JSON přes `JSONSerialization` do `[String: Any]`, nereferencuje
  `SHExtractionResult` ani žádný app typ. Importuje jen `Cocoa` + `QuickLookUI`.
  Je obalený `#if QUICK_LOOK_EXTENSION` guardem a NENÍ v žádném targetu.
- UTI je v `SpiceHarvester/Info.plist`: identifikátor `DavidMasin.SpiceHarvester.result`,
  přípona `spice-result.json`, conforms `public.json` (`UTExportedTypeDeclarations`
  + `CFBundleDocumentTypes`).
- `SHExportService` už ukládá per-document soubory jako `*.spice-result.json`.
- Projekt používá `PBXFileSystemSynchronizedRootGroup` — každý target má vlastní
  kořenovou složku (app / Tests / UITests). Aktuálně 3 targety.

## Přístup

**A) Vlastní synchronizovaná složka `SpiceHarvesterQuickLook/`** (zvolено).
Kopíruje vzor projektu (target = jedna synchronizovaná složka), zdroj je jediný
soubor, čistý zásah do pbxproj.

Zamítnuté alternativy:
- **B)** Nechat zdroj v `SpiceHarvester/QuickLook/` + cross-target membership
  exception (`PBXFileSystemSynchronizedBuildFileExceptionSet`) — křehčí, soubor
  by zůstal v synchronizované složce hlavní appky.
- **C)** Generovat projekt přes XcodeGen/`xcodeproj` — zbytečná závislost mimo repo.

## Design

### Soubory — nová složka `SpiceHarvesterQuickLook/`

1. **`SHQuickLookPreview.swift`** — přesunutý z `SpiceHarvester/QuickLook/`.
   Odstraní se `#if QUICK_LOOK_EXTENSION` guard (soubor žije jen v tomto targetu;
   hlavní app ho přes svou synchronizovanou složku nevidí). Hlavičkový komentář
   s „aktivačním návodem" se zkrátí na popis třídy. Logika renderu beze změny
   (XSS-safe escape `source_file`, dark-mode CSS, kanonická + ostatní pole).

2. **`Info.plist`** — extension bundle. Zdroj je **data-based** `QLPreviewProvider`
   (`providePreview(for:)` vrací `QLPreviewReply`), ne view-based, takže:
   - `NSExtension` → `NSExtensionPointIdentifier = com.apple.quicklook.preview`
   - `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).SHQuickLookPreview`
   - `NSExtensionAttributes` → `QLSupportedContentTypes = [DavidMasin.SpiceHarvester.result]`,
     `QLSupportsSearchableItems = false`
   - `QLIsDataBasedPreview = true` (data-based provider)

3. **`SpiceHarvesterQuickLook.entitlements`** — `com.apple.security.app-sandbox = true`,
   `com.apple.security.files.user-selected.read-only = true` (QL předává URL souboru;
   read-only sandbox stačí).

### Zásah do `project.pbxproj`

- Nová `PBXFileSystemSynchronizedRootGroup` pro `SpiceHarvesterQuickLook/`, přiřazená
  novému targetu.
- Nový `PBXNativeTarget` `SpiceHarvesterQuickLook`:
  - `productType = com.apple.product-type.app-extension`, produkt `SpiceHarvesterQuickLook.appex`
  - Build fáze: **Sources** (synchronizovaná složka), **Frameworks** (`QuickLookUI.framework`)
  - Debug/Release `XCBuildConfiguration`:
    - `PRODUCT_BUNDLE_IDENTIFIER = DavidMasin.SpiceHarvester.SpiceHarvesterQuickLook`
    - `INFOPLIST_FILE = SpiceHarvesterQuickLook/Info.plist`
    - `CODE_SIGN_ENTITLEMENTS = SpiceHarvesterQuickLook/SpiceHarvesterQuickLook.entitlements`
    - `MACOSX_DEPLOYMENT_TARGET = 15.6`, `SWIFT_VERSION`, `GENERATE_INFOPLIST_FILE = NO`,
      `SKIP_INSTALL = YES`, `CODE_SIGN_STYLE = Automatic`/`Sign to Run Locally` dle appky
  - `buildConfigurationList` pro target.
- Registrace targetu v `targets` projektu + jeho config listu.
- **Hlavní app target**:
  - `PBXTargetDependency` na `SpiceHarvesterQuickLook`.
  - **Embed App Extensions** Copy Files fáze (`dstSubfolderSpec = 13` → PlugIns),
    `RemoveHeadersOnCopy`, vkládající `SpiceHarvesterQuickLook.appex`.

### Úklid

- Smazat prázdnou `SpiceHarvester/QuickLook/`.
- P2 backlog: #1 → ✅ Hotovo (a srovnat „Nehotovo" řádek v tabulce „už hotové").

## Ověření

1. `xcodebuild build -scheme SpiceHarvester` postaví **oba** targety a embedne
   `.appex` do `SpiceHarvester.app/Contents/PlugIns/`.
2. Kontrola embedu: `.appex` existuje v `Contents/PlugIns/`.
3. Render náhledu: `qlmanage -p <vzorek>.spice-result.json` (nebo `qlmanage -g`)
   na ukázkovém výstupu — ověří, že extension produkuje HTML, ne raw JSON.

## Mimo rozsah

- Žádná změna logiky renderu (jen přesun + odstranění guardu).
- Žádná notarizace/distribuce (ad-hoc „Sign to Run Locally" zůstává).
- Quick Look pro projektové soubory `.spiceharvester` (to spadá pod #2 DocumentGroup).

## Rizika

- **Hand-edit `project.pbxproj`** je hlavní riziko — mitigováno buildem ihned po
  zásahu (build selže hlasitě, když je struktura špatně).
- Ad-hoc podpis: appex se embedne i podepíše ad-hoc bez problému; QL ve Finderu
  může vyžadovat registraci appky v LaunchServices — `qlmanage -p` testuje přímo.
