# Quick Look Preview Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Přidat Quick Look Preview Extension target, který ve Finderu renderuje `*.spice-result.json` jako strukturovaný HTML náhled místo raw JSONu.

**Architecture:** Nový app-extension target `SpiceHarvesterQuickLook` s vlastní synchronizovanou složkou (vzor projektu). Jediný soběstačný zdroj (`SHQuickLookPreview.swift`), vlastní Info.plist + entitlements. Target se embedne do hlavní appky přes Copy Files (PlugIns) fázi + target dependency. Vše hand-editem `project.pbxproj` (objectVersion 77), ověřeno buildem.

**Tech Stack:** Swift, QuickLookUI (`QLPreviewProvider`, data-based), Xcode `project.pbxproj` (PBXFileSystemSynchronizedRootGroup), `xcodebuild`, `qlmanage`.

**Spec:** `docs/superpowers/specs/2026-06-21-quicklook-extension-target-design.md`

---

## Nové UUID objektů (project.pbxproj)

Všechny jsou 24-hex a nekolidují s existujícími (`63A1C0xx…`):

| Účel | ID |
|---|---|
| Synchronized root group `SpiceHarvesterQuickLook` | `DDCCDDCC2E0870CA00F34701` |
| Product file ref `SpiceHarvesterQuickLook.appex` | `DDCCDDCC2E0870CA00F34702` |
| PBXNativeTarget | `DDCCDDCC2E0870CA00F34703` |
| Sources build phase | `DDCCDDCC2E0870CA00F34704` |
| Frameworks build phase | `DDCCDDCC2E0870CA00F34705` |
| Resources build phase | `DDCCDDCC2E0870CA00F34706` |
| XCConfigurationList (target) | `DDCCDDCC2E0870CA00F34707` |
| XCBuildConfiguration Debug | `DDCCDDCC2E0870CA00F34708` |
| XCBuildConfiguration Release | `DDCCDDCC2E0870CA00F34709` |
| PBXContainerItemProxy (app→ext dep) | `DDCCDDCC2E0870CA00F34710` |
| PBXTargetDependency | `DDCCDDCC2E0870CA00F34711` |
| PBXCopyFilesBuildPhase (Embed) | `DDCCDDCC2E0870CA00F34712` |
| PBXBuildFile (appex v embed) | `DDCCDDCC2E0870CA00F34713` |

Existující ID, na která se odkazuje:
- App target: `63A1C0D52E0870C900F34733`
- App Sources/Frameworks/Resources: `63A1C0D22…` / `63A1C0D32…` / `63A1C0D42…`
- mainGroup: `63A1C0CD2E0870C900F34733`
- Products group: `63A1C0D72E0870C900F34733`
- Project object: `63A1C0CE2E0870C900F34733`
- App target attributes klíč: `63A1C0D52E0870C900F34733`

---

## File Structure

- `SpiceHarvesterQuickLook/SHQuickLookPreview.swift` — přesun z `SpiceHarvester/QuickLook/`, bez `#if` guardu. Jediný zdroj extensionu.
- `SpiceHarvesterQuickLook/Info.plist` — NSExtension (data-based QL provider) + QLSupportedContentTypes.
- `SpiceHarvesterQuickLook/SpiceHarvesterQuickLook.entitlements` — sandbox read-only.
- `SpiceHarvester.xcodeproj/project.pbxproj` — nový target + embed + dependency.
- `SpiceHarvester/QuickLook/` — smazat (prázdná po přesunu).
- `docs/P2_BACKLOG_DEFERRED.md` — #1 → hotovo.

---

## Task 1: Vytvoř soubory extensionu

**Files:**
- Create: `SpiceHarvesterQuickLook/SHQuickLookPreview.swift`
- Create: `SpiceHarvesterQuickLook/Info.plist`
- Create: `SpiceHarvesterQuickLook/SpiceHarvesterQuickLook.entitlements`
- Delete: `SpiceHarvester/QuickLook/SHQuickLookPreview.swift`

- [ ] **Step 1: Vytvoř zdroj extensionu** (bez `#if` guardu — soubor žije jen v tomto targetu)

Create `SpiceHarvesterQuickLook/SHQuickLookPreview.swift`:

```swift
import Cocoa
import QuickLookUI

/// Rich Quick Look preview for `*.spice-result.json` files. Default JSON
/// preview shows raw text; this provider renders a structured table with
/// the canonical fields (patient name, lab values list, diagnoses) so
/// the user can scan results in Finder without opening the app.
final class SHQuickLookPreview: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL

        return QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 720, height: 540)
        ) { _ in
            let data = try Data(contentsOf: url)
            return Self.htmlPreview(for: data).data(using: .utf8) ?? Data()
        }
    }

    /// Best-effort HTML rendering of an `SHExtractionResult`-shaped JSON.
    /// Keys we don't recognize are surfaced under a "Other fields" section
    /// so the preview never silently drops data.
    private static func htmlPreview(for data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return defaultHTML(title: "Spice Harvester result", body: "<p>Soubor není validní JSON.</p>")
        }

        var rows: [String] = []
        let canonicalKeys = [
            "patient_name", "patient_id", "birth_date",
            "admission_date", "discharge_date",
            "diagnoses", "medication", "lab_values",
            "discharge_status", "warnings", "confidence"
        ]
        for key in canonicalKeys where json[key] != nil {
            rows.append(rowHTML(key: key, value: json[key] ?? "—"))
        }
        let others = json.keys.filter { !canonicalKeys.contains($0) && $0 != "source_file" }.sorted()
        for key in others {
            rows.append(rowHTML(key: key, value: json[key] ?? "—"))
        }

        // `source_file` is user-controlled (filename of the source PDF),
        // so we MUST html-escape before injecting into <title> / <h1>.
        // Without this, a filename like `evil<script>...</script>.pdf`
        // executes from file:// origin in WebKit (XSS risk specific to
        // Quick Look previews).
        let rawTitle = (json["source_file"] as? String) ?? "Spice Harvester result"
        let body = "<table>\(rows.joined())</table>"
        return defaultHTML(title: rawTitle, body: body)
    }

    private static func rowHTML(key: String, value: Any) -> String {
        let formatted: String
        switch value {
        case let arr as [Any]:
            let items = arr.map { "<li>\(escape("\($0)"))</li>" }.joined()
            formatted = "<ul>\(items)</ul>"
        case let dict as [String: Any]:
            let inner = dict.map { "<b>\(escape($0.key))</b>: \(escape("\($0.value)"))" }.joined(separator: ", ")
            formatted = inner
        default:
            formatted = escape("\(value)")
        }
        return "<tr><th>\(escape(key))</th><td>\(formatted)</td></tr>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func defaultHTML(title: String, body: String) -> String {
        // Escape title at every injection point. Body is built up of
        // already-escaped row fragments (see `rowHTML`), so it doesn't
        // get re-escaped here — escaping pre-escaped content would
        // produce visible `&amp;lt;` instead of `<`.
        let safeTitle = escape(title)
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(safeTitle)</title>
        <style>
        body{font:13px -apple-system,system-ui;margin:18px;color:#222}
        h1{font-size:16px;margin:0 0 12px;color:#444}
        table{width:100%;border-collapse:collapse}
        th,td{padding:6px 8px;border-bottom:1px solid #eee;vertical-align:top;text-align:left}
        th{width:32%;color:#666;font-weight:500}
        ul{margin:0;padding-left:18px}
        @media (prefers-color-scheme:dark){
          body{background:#1e1e1e;color:#ddd}
          h1{color:#bbb}
          th{color:#888}
          th,td{border-color:#333}
        }
        </style></head>
        <body><h1>\(safeTitle)</h1>\(body)</body></html>
        """
    }
}
```

- [ ] **Step 2: Vytvoř Info.plist** (data-based QLPreviewProvider)

Create `SpiceHarvesterQuickLook/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>QLIsDataBasedPreview</key>
	<true/>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.quicklook.preview</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).SHQuickLookPreview</string>
		<key>NSExtensionAttributes</key>
		<dict>
			<key>QLSupportedContentTypes</key>
			<array>
				<string>DavidMasin.SpiceHarvester.result</string>
			</array>
			<key>QLSupportsSearchableItems</key>
			<false/>
		</dict>
	</dict>
</dict>
</plist>
```

- [ ] **Step 3: Vytvoř entitlements**

Create `SpiceHarvesterQuickLook/SpiceHarvesterQuickLook.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 4: Smaž starý zdroj**

Run: `git rm SpiceHarvester/QuickLook/SHQuickLookPreview.swift && rmdir SpiceHarvester/QuickLook 2>/dev/null; true`
Expected: starý soubor odstraněn. (Složka je teď prázdná.)

- [ ] **Step 5: Ověř, že hlavní app pořád builduje** (nový soubor zatím není v žádném targetu, takže build je beze změny)

Run: `xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add SpiceHarvesterQuickLook SpiceHarvester/QuickLook
git commit -m "QuickLook: zdroj extensionu + Info.plist + entitlements (zatím bez targetu)"
```

---

## Task 2: Přidej extension target do project.pbxproj

Provádí se sérií přesných `Edit` zásahů do `SpiceHarvester.xcodeproj/project.pbxproj`. Po všech zásazích se buildí — projekt je validní až po dokončení celé Tasky, proto se commituje až na konci.

**Files:**
- Modify: `SpiceHarvester.xcodeproj/project.pbxproj`

- [ ] **Step 1: PBXBuildFile + PBXContainerItemProxy** — vlož na začátek `objects` za řádek `objects = {`

Najdi:
```
	objects = {

/* Begin PBXBuildFile section */
```
Pokud sekce `PBXBuildFile` neexistuje (v tomto projektu zatím není), vlož ji hned za `objects = {`:

Najdi přesně:
```
	objectVersion = 77;
	objects = {

/* Begin PBXContainerItemProxy section */
```
Nahraď za:
```
	objectVersion = 77;
	objects = {

/* Begin PBXBuildFile section */
		DDCCDDCC2E0870CA00F34713 /* SpiceHarvesterQuickLook.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = DDCCDDCC2E0870CA00F34702 /* SpiceHarvesterQuickLook.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		DDCCDDCC2E0870CA00F34710 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = 63A1C0CE2E0870C900F34733 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = DDCCDDCC2E0870CA00F34703;
			remoteInfo = SpiceHarvesterQuickLook;
		};
```

- [ ] **Step 2: PBXCopyFilesBuildPhase (Embed)** — vlož novou sekci za konec `PBXContainerItemProxy`

Najdi:
```
/* End PBXContainerItemProxy section */
```
Nahraď za:
```
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
		DDCCDDCC2E0870CA00F34712 /* Embed Foundation Extensions */ = {
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 13;
			files = (
				DDCCDDCC2E0870CA00F34713 /* SpiceHarvesterQuickLook.appex in Embed Foundation Extensions */,
			);
			name = "Embed Foundation Extensions";
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXCopyFilesBuildPhase section */
```

- [ ] **Step 3: PBXFileReference pro .appex** — přidej do `PBXFileReference` sekce

Najdi:
```
		63A1C0EE2E0870CA00F34733 /* SpiceHarvesterUITests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = SpiceHarvesterUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */
```
Nahraď za:
```
		63A1C0EE2E0870CA00F34733 /* SpiceHarvesterUITests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = SpiceHarvesterUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
		DDCCDDCC2E0870CA00F34702 /* SpiceHarvesterQuickLook.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = SpiceHarvesterQuickLook.appex; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */
```

- [ ] **Step 4: Synchronized root group** — přidej do `PBXFileSystemSynchronizedRootGroup` sekce

Najdi:
```
		63A1C0F12E0870CA00F34733 /* SpiceHarvesterUITests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = SpiceHarvesterUITests;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */
```
Nahraď za:
```
		63A1C0F12E0870CA00F34733 /* SpiceHarvesterUITests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = SpiceHarvesterUITests;
			sourceTree = "<group>";
		};
		DDCCDDCC2E0870CA00F34701 /* SpiceHarvesterQuickLook */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = SpiceHarvesterQuickLook;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */
```

- [ ] **Step 5: Frameworks + Sources + Resources build phases** pro nový target — přidej do příslušných sekcí

Najdi (konec Frameworks sekce):
```
		63A1C0EB2E0870CA00F34733 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */
```
Nahraď za:
```
		63A1C0EB2E0870CA00F34733 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		DDCCDDCC2E0870CA00F34705 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */
```

Najdi (konec Resources sekce):
```
		63A1C0EC2E0870CA00F34733 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */
```
Nahraď za:
```
		63A1C0EC2E0870CA00F34733 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		DDCCDDCC2E0870CA00F34706 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */
```

Najdi (konec Sources sekce):
```
		63A1C0EA2E0870CA00F34733 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */
```
Nahraď za:
```
		63A1C0EA2E0870CA00F34733 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		DDCCDDCC2E0870CA00F34704 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */
```

> Pozn.: Sources fáze je prázdná schválně — soubory dodává `fileSystemSynchronizedGroups` na targetu (synchronizovaná složka). QuickLookUI se přilinkuje autolinkem ze `import QuickLookUI`, proto je Frameworks fáze prázdná (stejně jako u hlavní appky).

- [ ] **Step 6: Embed fáze do app targetu + nový PBXNativeTarget**

Najdi app target blok:
```
		63A1C0D52E0870C900F34733 /* SpiceHarvester */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 63A1C0F82E0870CA00F34733 /* Build configuration list for PBXNativeTarget "SpiceHarvester" */;
			buildPhases = (
				63A1C0D22E0870C900F34733 /* Sources */,
				63A1C0D32E0870C900F34733 /* Frameworks */,
				63A1C0D42E0870C900F34733 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				63A1C0D82E0870C900F34733 /* SpiceHarvester */,
			);
			name = SpiceHarvester;
			packageProductDependencies = (
			);
			productName = SpiceHarvester;
			productReference = 63A1C0D62E0870C900F34733 /* SpiceHarvester.app */;
			productType = "com.apple.product-type.application";
		};
```
Nahraď za:
```
		63A1C0D52E0870C900F34733 /* SpiceHarvester */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 63A1C0F82E0870CA00F34733 /* Build configuration list for PBXNativeTarget "SpiceHarvester" */;
			buildPhases = (
				63A1C0D22E0870C900F34733 /* Sources */,
				63A1C0D32E0870C900F34733 /* Frameworks */,
				63A1C0D42E0870C900F34733 /* Resources */,
				DDCCDDCC2E0870CA00F34712 /* Embed Foundation Extensions */,
			);
			buildRules = (
			);
			dependencies = (
				DDCCDDCC2E0870CA00F34711 /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				63A1C0D82E0870C900F34733 /* SpiceHarvester */,
			);
			name = SpiceHarvester;
			packageProductDependencies = (
			);
			productName = SpiceHarvester;
			productReference = 63A1C0D62E0870C900F34733 /* SpiceHarvester.app */;
			productType = "com.apple.product-type.application";
		};
		DDCCDDCC2E0870CA00F34703 /* SpiceHarvesterQuickLook */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = DDCCDDCC2E0870CA00F34707 /* Build configuration list for PBXNativeTarget "SpiceHarvesterQuickLook" */;
			buildPhases = (
				DDCCDDCC2E0870CA00F34704 /* Sources */,
				DDCCDDCC2E0870CA00F34705 /* Frameworks */,
				DDCCDDCC2E0870CA00F34706 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				DDCCDDCC2E0870CA00F34701 /* SpiceHarvesterQuickLook */,
			);
			name = SpiceHarvesterQuickLook;
			packageProductDependencies = (
			);
			productName = SpiceHarvesterQuickLook;
			productReference = DDCCDDCC2E0870CA00F34702 /* SpiceHarvesterQuickLook.appex */;
			productType = "com.apple.product-type.app-extension";
		};
```

- [ ] **Step 7: Registruj target v PBXProject** (targets list + TargetAttributes)

Najdi:
```
				TargetAttributes = {
					63A1C0D52E0870C900F34733 = {
						CreatedOnToolsVersion = 16.4;
					};
```
Nahraď za:
```
				TargetAttributes = {
					63A1C0D52E0870C900F34733 = {
						CreatedOnToolsVersion = 16.4;
					};
					DDCCDDCC2E0870CA00F34703 = {
						CreatedOnToolsVersion = 16.4;
					};
```

Najdi:
```
			targets = (
				63A1C0D52E0870C900F34733 /* SpiceHarvester */,
				63A1C0E32E0870CA00F34733 /* SpiceHarvesterTests */,
				63A1C0ED2E0870CA00F34733 /* SpiceHarvesterUITests */,
			);
```
Nahraď za:
```
			targets = (
				63A1C0D52E0870C900F34733 /* SpiceHarvester */,
				DDCCDDCC2E0870CA00F34703 /* SpiceHarvesterQuickLook */,
				63A1C0E32E0870CA00F34733 /* SpiceHarvesterTests */,
				63A1C0ED2E0870CA00F34733 /* SpiceHarvesterUITests */,
			);
```

- [ ] **Step 8: Přidej .appex do Products group**

Najdi:
```
		63A1C0D72E0870C900F34733 /* Products */ = {
			isa = PBXGroup;
			children = (
				63A1C0D62E0870C900F34733 /* SpiceHarvester.app */,
				63A1C0E42E0870CA00F34733 /* SpiceHarvesterTests.xctest */,
				63A1C0EE2E0870CA00F34733 /* SpiceHarvesterUITests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		};
```
Nahraď za:
```
		63A1C0D72E0870C900F34733 /* Products */ = {
			isa = PBXGroup;
			children = (
				63A1C0D62E0870C900F34733 /* SpiceHarvester.app */,
				63A1C0E42E0870CA00F34733 /* SpiceHarvesterTests.xctest */,
				63A1C0EE2E0870CA00F34733 /* SpiceHarvesterUITests.xctest */,
				DDCCDDCC2E0870CA00F34702 /* SpiceHarvesterQuickLook.appex */,
			);
			name = Products;
			sourceTree = "<group>";
		};
```

- [ ] **Step 9: PBXTargetDependency**

Najdi:
```
/* End PBXTargetDependency section */
```
Nahraď za:
```
		DDCCDDCC2E0870CA00F34711 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = DDCCDDCC2E0870CA00F34703 /* SpiceHarvesterQuickLook */;
			targetProxy = DDCCDDCC2E0870CA00F34710 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */
```

- [ ] **Step 10: XCBuildConfiguration Debug + Release pro target**

Najdi:
```
/* End XCBuildConfiguration section */
```
Nahraď za:
```
		DDCCDDCC2E0870CA00F34708 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = SpiceHarvesterQuickLook/SpiceHarvesterQuickLook.entitlements;
				"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEAD_CODE_STRIPPING = YES;
				DEVELOPMENT_TEAM = 839ECBL3D2;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = SpiceHarvesterQuickLook/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
					"@executable_path/../../../../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 15.6;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = DavidMasin.SpiceHarvester.SpiceHarvesterQuickLook;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		DDCCDDCC2E0870CA00F34709 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = SpiceHarvesterQuickLook/SpiceHarvesterQuickLook.entitlements;
				"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEAD_CODE_STRIPPING = YES;
				DEVELOPMENT_TEAM = 839ECBL3D2;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = SpiceHarvesterQuickLook/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
					"@executable_path/../../../../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 15.6;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = DavidMasin.SpiceHarvester.SpiceHarvesterQuickLook;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */
```

- [ ] **Step 11: XCConfigurationList pro target**

Najdi:
```
/* End XCConfigurationList section */
```
Nahraď za:
```
		DDCCDDCC2E0870CA00F34707 /* Build configuration list for PBXNativeTarget "SpiceHarvesterQuickLook" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				DDCCDDCC2E0870CA00F34708 /* Debug */,
				DDCCDDCC2E0870CA00F34709 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
```

- [ ] **Step 12: Build celého schématu** (postaví app + extension a embedne appex)

Run: `xcodebuild build -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. Když selže, zkontroluj přesnost zásahů (chybějící čárka/ID); v nouzi `git checkout SpiceHarvester.xcodeproj/project.pbxproj` a zopakuj.

- [ ] **Step 13: Ověř embed .appex v app bundle**

Run:
```bash
DD=$(xcodebuild -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -showBuildSettings -configuration Debug 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
ls -d "$DD/SpiceHarvester.app/Contents/PlugIns/SpiceHarvesterQuickLook.appex"
```
Expected: cesta existuje (appex je embednutý).

- [ ] **Step 14: Commit**

```bash
git add SpiceHarvester.xcodeproj/project.pbxproj
git commit -m "QuickLook: extension target + embed do appky (project.pbxproj)"
```

---

## Task 3: Ověř render náhledu (best-effort)

**Files:** žádné (jen ověření)

- [ ] **Step 1: Vytvoř ukázkový výsledek**

Run:
```bash
cat > /tmp/ukazka.spice-result.json <<'JSON'
{"source_file":"zprava.pdf","patient_name":"Jan Novák","diagnoses":["I10","E11"],"lab_values":{"CRP":"5.2"},"confidence":0.91}
JSON
```

- [ ] **Step 2: Zaregistruj app a vyrenderuj náhled**

Run:
```bash
DD=$(xcodebuild -project SpiceHarvester.xcodeproj -scheme SpiceHarvester -showBuildSettings -configuration Debug 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$DD/SpiceHarvester.app"
rm -rf /tmp/qlout && qlmanage -p /tmp/ukazka.spice-result.json -o /tmp/qlout 2>&1 | tail -5
ls -R /tmp/qlout
```
Expected: `qlmanage` vyrobí náhledový výstup v `/tmp/qlout/ukazka.spice-result.json.qlpreview` (případně `.html` uvnitř). Náhled obsahuje HTML tabulku, ne raw JSON.

> Pozn.: V ad-hoc/dev buildu nemusí Finder QL extension hned zaregistrovat; `lsregister` to vynutí. Pokud `qlmanage` přesto vrátí prázdno, **hard gate je Task 2 (build + embed)** — render lze ověřit ručně ve Finderu (mezerník) po spuštění appky. Tento krok je informativní.

---

## Task 4: Dokumentace + finální commit

**Files:**
- Modify: `docs/P2_BACKLOG_DEFERRED.md`

- [ ] **Step 1: Aktualizuj P2 backlog** — přesuň #1 mezi hotové

V `docs/P2_BACKLOG_DEFERRED.md` ve status tabulce změň řádek Quick Look:

Najdi:
```
| Quick Look provider — zdroj + UTI/export | ✅ Zdroj `SHQuickLookPreview.swift` (guarded) + UTI/export `.spice-result.json` hotové; **Xcode extension target chybí** (#1 níže) |
```
Nahraď za:
```
| Quick Look provider (extension target) | ✅ Hotovo — `SpiceHarvesterQuickLook` app-extension target, data-based `QLPreviewProvider`, embed do appky |
```

A v tabulce „už hotové" řádek `Quick Look Preview Extension target` přepiš z „📋 Nehotovo …" na:
```
| Quick Look Preview Extension target | ✅ Hotovo | `SpiceHarvesterQuickLook` target (app-extension) se zdrojem `SHQuickLookPreview.swift`, Info.plist (`com.apple.quicklook.preview`, `QLSupportedContentTypes`), entitlements, embed do appky přes Copy Files (PlugIns). |
```

A v sekci #1 (její detail výše v dokumentu) doplň na začátek banner `> ✅ HOTOVO — viz commit.` nebo sekci zkrať na poznámku „hotovo".

- [ ] **Step 2: Aktualizuj sekci „Priority" / číslování, pokud na #1 odkazuje**

Zkontroluj, že žádný text už neoznačuje Quick Look jako otevřený TODO. Otevřený zbývá jen DocumentGroup (#2).

- [ ] **Step 3: Commit**

```bash
git add docs/P2_BACKLOG_DEFERRED.md
git commit -m "Docs: Quick Look extension target hotový, P2 backlog aktualizován"
```

---

## Self-Review (provedeno při psaní)

- **Spec coverage:** target (Task 2), 3 soubory (Task 1), embed + dependency (Task 2 step 6/9), UTI match (Info.plist v Task 1 step 2 = `DavidMasin.SpiceHarvester.result`), úklid složky (Task 1 step 4), ověření build+embed+render (Task 2 step 12-13, Task 3), backlog (Task 4) — vše pokryto.
- **Type/ID consistency:** všech 13 nových ID použito konzistentně mezi definicí a referencí; `NSExtensionPrincipalClass` = `$(PRODUCT_MODULE_NAME).SHQuickLookPreview` odpovídá názvu třídy v Task 1 step 1.
- **Placeholders:** žádné — každý krok má konkrétní obsah/příkaz.
