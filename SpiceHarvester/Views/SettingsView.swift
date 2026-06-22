import SwiftUI
import AppKit

/// Native macOS Settings sheet (Cmd+,). Hosts everything that the user normally
/// configures once and forgets: pipeline performance knobs, request timeout,
/// OCR backend, and inference-cache bypass. Keeping these out of the main
/// window de-clutters the configuration column without losing access.
struct SettingsView: View {
    /// App-level předvolby (sdílené). Settings je app-level scéna bez document VM.
    @Bindable var global: SHGlobalState
    @State private var selectedTab: SettingsTab = .performance
    /// Substring search across all tabs. Each tab declares its own
    /// keyword bag (`SettingsTab.searchKeywords`); typing here auto-selects
    /// the first matching tab so the user lands on relevant content
    /// without remembering which tab hosts which knob ("kde je throttle?").
    @State private var searchText: String = ""
    @State private var pandocStatusText = "Zjišťuji…"
    @State private var pdftotextStatusText = "Zjišťuji…"
    @State private var in2csvStatusText = "Zjišťuji…"
    @State private var ocrmypdfStatusText = "Zjišťuji…"
    @State private var tesseractStatusText = "Zjišťuji…"
    /// Stav nástrojů probneme jen jednou za sezení, ne při každém zobrazení OCR tabu.
    @State private var toolStatusProbed = false
    @FocusState private var ocrLanguagesFocused: Bool
    /// Jazyky, které má nainstalovaný tesseract (`--list-langs`) — pro nápovědu
    /// a varování u pole „Jazyky". Prázdné = nezjištěno (tesseract chybí).
    @State private var availableOCRLanguages: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Text(selectedTab.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.top, 12)

            // Settings search: bridges the "split between main window and
            // Cmd+, sheet" friction that the audit flagged. The user types
            // a fragment of any setting name and we jump to the right tab.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Hledat v nastavení…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 280)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.top, 6)
            .onChange(of: searchText) { _, newValue in
                if let match = SettingsTab.firstMatching(query: newValue) {
                    selectedTab = match
                }
            }

            HStack(spacing: 18) {
                ForEach(SettingsTab.allCases) { tab in
                    settingsTabButton(tab)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 12)

            Divider()

            selectedTabContent
        }
        // Resizovatelný rozsah místo pevné velikosti — ideální = původní
        // 620×580 (beze změny prvního spuštění), ale uživatel může okno
        // zvětšit/zmenšit. `SettingsWindowConfigurator` níže udělá okno
        // resizable a uloží frame přes AppKit autosave (stejně jako hlavní okno).
        .frame(minWidth: 480, idealWidth: 620, maxWidth: .infinity,
               minHeight: 460, idealHeight: 580, maxHeight: .infinity)
        .background(SettingsWindowConfigurator())
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .performance:
            performanceTab
        case .ocr:
            ocrTab
        case .cache:
            cacheTab
        }
    }

    private func settingsTabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 27, weight: .regular))
                    .frame(height: 31)
                Text(tab.title)
                    .font(.title3)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(width: 76, height: 76)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: – Performance

    private var performanceTab: some View {
        Form {
            Section {
                Stepper(
                    value: $global.prefs.maxConcurrentInference,
                    in: 1...16
                ) {
                    LabeledContent("Souběžné inference požadavky") {
                        Text("\(global.prefs.maxConcurrentInference)")
                            .monospacedDigit()
                    }
                }
                .help("Kolik souběžných HTTP požadavků na AI server může pipeline držet zároveň. Nemá efekt v režimu CONSOLIDATE (vždy 1 požadavek).")

                Stepper(
                    value: $global.prefs.maxConcurrentPDFWorkers,
                    in: 1...16
                ) {
                    LabeledContent("Souběžné PDF/OCR workery") {
                        Text("\(global.prefs.maxConcurrentPDFWorkers)")
                            .monospacedDigit()
                    }
                }
                .help("Kolik PDF se zpracovává paralelně při fázi předzpracování (parsování textu + OCR).")

                Stepper(
                    value: $global.prefs.throttleDelayMs,
                    in: 0...2_000,
                    step: 50
                ) {
                    LabeledContent("Throttle mezi požadavky") {
                        Text("\(global.prefs.throttleDelayMs) ms")
                            .monospacedDigit()
                    }
                }
                .help("Pauza vložená mezi po sobě jdoucími inference požadavky. Pomáhá serverům s pomalou KV cache.")
            } header: {
                Text("Souběžnost")
            }

            Section {
                Stepper(
                    value: $global.prefs.modelContextTokens,
                    in: 4_096...1_048_576,
                    step: 4_096
                ) {
                    LabeledContent("Kontext modelu") {
                        Text("\(global.prefs.modelContextTokens / 1024)k tokenů")
                            .monospacedDigit()
                    }
                }
                .help("Velikost kontextového okna načteného modelu. Používá se pro pre-flight kontrolu v CONSOLIDATE režimu, aby nedošlo k HTTP 400 n_keep > n_ctx.")

                Stepper(
                    value: $global.prefs.requestTimeoutSeconds,
                    in: 60...3_600,
                    step: 60
                ) {
                    LabeledContent("Timeout požadavku") {
                        Text(formatTimeout(global.prefs.requestTimeoutSeconds))
                            .monospacedDigit()
                    }
                }
                .help("Max doba jednoho HTTP požadavku na lokální AI server. Při zaseknutí modelu se požadavek po této době zruší a opakuje.")
            } header: {
                Text("Model a HTTP")
            }
        }
        .formStyle(.grouped)
        .onChange(of: global.prefs.maxConcurrentInference) { _, _ in global.savePreferences() }
        .onChange(of: global.prefs.maxConcurrentPDFWorkers) { _, _ in global.savePreferences() }
        .onChange(of: global.prefs.throttleDelayMs) { _, _ in global.savePreferences() }
        .onChange(of: global.prefs.modelContextTokens) { _, _ in global.savePreferences() }
        .onChange(of: global.prefs.requestTimeoutSeconds) { _, _ in
            // Otevřené dokumenty si nový timeout načtou z `global.prefs` při
            // příštím rebuildu LM klienta (před během / po změně serveru).
            global.savePreferences()
        }
    }

    // MARK: – OCR

    private var ocrTab: some View {
        // Rozdělené do menších computed properties — jediný velký Form přetěžoval
        // SwiftUI type-checker ("unable to type-check this expression in reasonable time").
        Form {
            ocrBackendSection
            ocrmypdfConfigSection
            localToolsSection
            thirdPartyLicenseSection
        }
        .formStyle(.grouped)
        .onChange(of: global.prefs.officeConversionEnabled) { _, _ in global.savePreferences() }
        .onChange(of: global.prefs.popplerPDFTextEnabled) { _, _ in global.savePreferences() }
        .onChange(of: global.prefs.spreadsheetConversionEnabled) { _, _ in global.savePreferences() }
        // Během psaní debounced persist (jako u jména serveru) — žádný write
        // storm, ale ani ztráta editace bez commitu. Při opuštění pole / Enteru
        // navíc prázdnou hodnotu normalizujeme na default, ať UI i persistence
        // odpovídají runtime fallbacku.
        .onChange(of: global.prefs.ocrLanguages) { _, _ in global.savePreferences() }
        .onChange(of: ocrLanguagesFocused) { _, focused in
            if !focused { commitOCRLanguages() }
        }
        .onChange(of: global.prefs.ocrTimeoutSeconds) { _, _ in global.savePreferences() }
        .task {
            // Stav nástrojů se v rámci sezení nemění; probni `--version` jen jednou,
            // ne při každém přepnutí zpět na OCR tab (5 podprocesů pokaždé).
            guard !toolStatusProbed else { return }
            toolStatusProbed = true
            let registry = SHToolRegistry()
            pandocStatusText = Self.toolStatusLabel(await registry.status(for: .pandoc))
            pdftotextStatusText = Self.toolStatusLabel(await registry.status(for: .pdftotext))
            in2csvStatusText = Self.toolStatusLabel(await registry.status(for: .in2csv))
            ocrmypdfStatusText = Self.toolStatusLabel(await registry.status(for: .ocrmypdf))
            tesseractStatusText = Self.toolStatusLabel(await registry.status(for: .tesseract))

            // Dostupné OCR jazyky z tesseractu (seznam jde na stdout i stderr).
            if let result = try? await SHToolRuntime().run(.tesseract, arguments: ["--list-langs"], timeout: 10) {
                let combined = result.stdoutString + "\n" + result.stderrString
                availableOCRLanguages = SHOcrmypdfProvider.parseAvailableLanguages(from: combined)
            }
        }
    }

    private var ocrBackendSection: some View {
        Section {
            Picker("Backend", selection: Binding(
                get: { global.prefs.ocrBackend },
                set: { global.prefs.ocrBackend = $0; global.savePreferences() }
            )) {
                ForEach(SHOCRBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("OCR backend")
        } footer: {
            Text("Apple Vision běží lokálně bez AI serveru. oMLX/VLM posílá skenované PDF stránky do vybraného OCR/VLM modelu přes OpenAI-compatible chat completions. Vision→VLM zkusí nejdřív Vision a teprve pokud neuspěje, sáhne po VLM. ocrmypdf je lokální OCR přes tesseract bez AI serveru; když není k dispozici, použije se Apple Vision.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var ocrmypdfConfigSection: some View {
        Section {
            LabeledContent("Jazyky") {
                TextField("ces+slk+deu+pol+eng", text: $global.prefs.ocrLanguages)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 240)
                    .focused($ocrLanguagesFocused)
                    .onSubmit { commitOCRLanguages() }
            }
            if !unsupportedOCRLanguages.isEmpty {
                Label(
                    "Nedostupné jazyky: \(unsupportedOCRLanguages.joined(separator: ", ")) — ocrmypdf je přeskočí (fallback na Apple Vision). Doplň traineddata.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            Stepper(
                value: $global.prefs.ocrTimeoutSeconds,
                in: 60...3_600,
                step: 60
            ) {
                LabeledContent("Timeout") {
                    Text(formatTimeout(global.prefs.ocrTimeoutSeconds))
                        .monospacedDigit()
                }
            }
        } header: {
            Text("OCR ocrmypdf")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Jazyky tesseractu spojené znakem +. Bundlovaná tessdata obsahují jen ces/slk/deu/pol/eng; jiné jazyky vyžadují doplnit traineddata. Timeout omezuje jeden běh ocrmypdf nad dokumentem. Platí pro backend „ocrmypdf“.")
                if !availableOCRLanguages.isEmpty {
                    Text("Dostupné jazyky: \(availableOCRLanguages.sorted().joined(separator: ", "))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Kódy z pole „Jazyky", které tesseract nemá nainstalované (varování v UI).
    private var unsupportedOCRLanguages: [String] {
        SHOcrmypdfProvider.unsupportedLanguages(in: global.prefs.ocrLanguages, available: availableOCRLanguages)
    }

    /// Po dokončení editace jazyků: prázdné/whitespace → default (shodně s
    /// `SHOcrmypdfProvider`), pak persist. Volá se z onSubmit i při opuštění pole.
    private func commitOCRLanguages() {
        let normalized = SHOcrmypdfProvider.normalizedLanguages(global.prefs.ocrLanguages)
        if global.prefs.ocrLanguages != normalized { global.prefs.ocrLanguages = normalized }
        global.savePreferences()
    }

    private var localToolsSection: some View {
        Section {
            Toggle(isOn: $global.prefs.officeConversionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Konverze office dokumentů (pandoc)")
                    Text("DOCX, ODT, RTF, HTML, EPUB se převedou na text přes pandoc.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $global.prefs.popplerPDFTextEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extrakce PDF textu přes pdftotext (-layout)")
                    Text("Místo PDFKit použije pdftotext; lépe zachová sloupce a tabulky.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $global.prefs.spreadsheetConversionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Konverze tabulek (XLSX/XLS) přes csvkit")
                    Text("Tabulky se převedou na CSV přes in2csv.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("pandoc") { Text(pandocStatusText).foregroundStyle(.secondary) }
            LabeledContent("pdftotext") { Text(pdftotextStatusText).foregroundStyle(.secondary) }
            LabeledContent("in2csv") { Text(in2csvStatusText).foregroundStyle(.secondary) }
            LabeledContent("ocrmypdf") { Text(ocrmypdfStatusText).foregroundStyle(.secondary) }
            LabeledContent("tesseract") { Text(tesseractStatusText).foregroundStyle(.secondary) }
        } header: {
            Text("Lokální nástroje")
        } footer: {
            Text("Nástroje běží lokálně. Pokud nejsou k dispozici, použije se nativní zpracování (PDFKit/Vision).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var thirdPartyLicenseSection: some View {
        Section {
            LabeledContent("pandoc") { Text("GPL-2.0+").foregroundStyle(.secondary) }
            LabeledContent("poppler (pdftotext)") { Text("GPL-2.0/3.0").foregroundStyle(.secondary) }
            LabeledContent("csvkit") { Text("MIT").foregroundStyle(.secondary) }
            LabeledContent("tesseract") { Text("Apache-2.0").foregroundStyle(.secondary) }
            LabeledContent("ocrmypdf") { Text("MPL-2.0").foregroundStyle(.secondary) }
            LabeledContent("Ghostscript (gs)") { Text("AGPL-3.0").foregroundStyle(.secondary) }
        } header: {
            Text("Licence třetích stran")
        } footer: {
            Text("Nástroje se spouštějí jako samostatné procesy. Při distribuci s bundlovaným Ghostscriptem (AGPL-3.0) je nutné zpřístupnit jeho zdrojový kód a přiložit text licence — viz docs/LICENCE_TRETI_STRANY.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: – Cache

    private var cacheTab: some View {
        Form {
            Section {
                Toggle(isOn: $global.prefs.bypassInferenceCache) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ignorovat cache LLM odpovědí")
                        Text("Pipeline nikdy nevrací uloženou odpověď a pokaždé volá server. Hodí se pro non-deterministické modely.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Inferenční cache")
            }

            Section {
                Text("Cache je per-projekt. „Vyčistit cache“ najdeš v menu **Pipeline** (cílí na aktivní okno projektu).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Cache projektu")
            }
        }
        .formStyle(.grouped)
        .onChange(of: global.prefs.bypassInferenceCache) { _, _ in global.savePreferences() }
    }

    private static func toolStatusLabel(_ status: SHToolRegistry.Status) -> String {
        switch status {
        case .available(let version): return "k dispozici (\(version))"
        case .missing: return "není v aplikaci"
        }
    }

    /// Compact timeout label: "90 s" under a minute, "2 m 30 s" above.
    private func formatTimeout(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let m = seconds / 60
        let s = seconds % 60
        return s == 0 ? "\(m) min" : "\(m) m \(s) s"
    }
}

/// Zpřístupní obklopující `NSWindow` Settings scény, udělá ho resizovatelným
/// a napojí na AppKit autosave — uživatel si zvolí velikost a ta přežije restart,
/// stejně jako u hlavního okna (viz `SHAppDelegate.mainWindowAutosaveName`).
/// SwiftUI `Settings { }` scéna sama velikost neukládá a při pevném frame ji
/// drží nezměnitelnou.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    /// Cocoa ukládá frame do NSGlobalDomain pod `NSWindow Frame {name}`.
    static let autosaveName = "SpiceHarvesterSettingsWindow"

    func makeNSView(context: Context) -> NSView { ConfiguratorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Naváže se přesně na okamžik připojení k oknu (ne na odhad jednoho ticku),
    /// takže `NSWindow` je zaručeně k dispozici. Frame aplikujeme async, aby
    /// restore nepřebil SwiftUI layout pass obsahu.
    private final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async {
                window.styleMask.insert(.resizable)
                // Restore uloženého frame, pak zapnout autosave budoucích změn.
                // Idempotentní — neaplikuj znovu, když už je autosave nastaven.
                if window.frameAutosaveName != SettingsWindowConfigurator.autosaveName {
                    window.setFrameUsingName(SettingsWindowConfigurator.autosaveName)
                    window.setFrameAutosaveName(SettingsWindowConfigurator.autosaveName)
                }
            }
        }
    }
}

private enum SettingsTab: CaseIterable, Identifiable {
    case performance
    case ocr
    case cache

    var id: Self { self }

    var title: String {
        switch self {
        case .performance: "Výkon"
        case .ocr: "OCR"
        case .cache: "Cache"
        }
    }

    var systemImage: String {
        switch self {
        case .performance: "speedometer"
        case .ocr: "doc.text.viewfinder"
        case .cache: "externaldrive"
        }
    }

    /// Substring keywords associated with each tab — searched as a flat
    /// concatenation. Adding a new setting? Append the user-visible
    /// fragments here so the search field finds it.
    var searchKeywords: [String] {
        switch self {
        case .performance:
            return [
                "výkon", "throttle", "souběžné", "concurrent", "inference",
                "pdf", "ocr workers", "kontext", "context", "tokenů",
                "timeout", "http", "model"
            ]
        case .ocr:
            return [
                "ocr", "vision", "vlm", "apple", "backend", "skenované",
                "rozpoznání", "scan", "pandoc", "pdftotext", "nástroje",
                "konverze", "docx", "office", "csvkit", "in2csv", "xlsx",
                "xls", "tabulky", "excel", "ocrmypdf", "tesseract", "sken"
            ]
        case .cache:
            return [
                "cache", "ignorovat", "bypass", "vyčistit", "clear",
                "uložené", "stored"
            ]
        }
    }

    /// Returns the first tab whose keywords contain the given query
    /// (case- and diacritic-insensitive). `nil` for empty / no-match.
    static func firstMatching(query: String) -> SettingsTab? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        for tab in allCases {
            if tab.searchKeywords.contains(where: { $0.lowercased().contains(q) }) {
                return tab
            }
        }
        return nil
    }
}
