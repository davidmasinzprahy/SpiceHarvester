import SwiftUI

/// Native macOS Settings sheet (Cmd+,). Hosts everything that the user normally
/// configures once and forgets: pipeline performance knobs, request timeout,
/// OCR backend, and inference-cache bypass. Keeping these out of the main
/// window de-clutters the configuration column without losing access.
struct SettingsView: View {
    @Bindable var vm: SHAppViewModel
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
        .frame(width: 620, height: 580)
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
                    value: $vm.config.maxConcurrentInference,
                    in: 1...16
                ) {
                    LabeledContent("Souběžné inference požadavky") {
                        Text("\(vm.config.maxConcurrentInference)")
                            .monospacedDigit()
                    }
                }
                .help("Kolik souběžných HTTP požadavků na AI server může pipeline držet zároveň. Nemá efekt v režimu CONSOLIDATE (vždy 1 požadavek).")

                Stepper(
                    value: $vm.config.maxConcurrentPDFWorkers,
                    in: 1...16
                ) {
                    LabeledContent("Souběžné PDF/OCR workery") {
                        Text("\(vm.config.maxConcurrentPDFWorkers)")
                            .monospacedDigit()
                    }
                }
                .help("Kolik PDF se zpracovává paralelně při fázi předzpracování (parsování textu + OCR).")

                Stepper(
                    value: $vm.config.throttleDelayMs,
                    in: 0...2_000,
                    step: 50
                ) {
                    LabeledContent("Throttle mezi požadavky") {
                        Text("\(vm.config.throttleDelayMs) ms")
                            .monospacedDigit()
                    }
                }
                .help("Pauza vložená mezi po sobě jdoucími inference požadavky. Pomáhá serverům s pomalou KV cache.")
            } header: {
                Text("Souběžnost")
            }

            Section {
                Stepper(
                    value: $vm.config.modelContextTokens,
                    in: 4_096...1_048_576,
                    step: 4_096
                ) {
                    LabeledContent("Kontext modelu") {
                        Text("\(vm.config.modelContextTokens / 1024)k tokenů")
                            .monospacedDigit()
                    }
                }
                .help("Velikost kontextového okna načteného modelu. Používá se pro pre-flight kontrolu v CONSOLIDATE režimu, aby nedošlo k HTTP 400 n_keep > n_ctx.")

                Stepper(
                    value: $vm.config.requestTimeoutSeconds,
                    in: 60...3_600,
                    step: 60
                ) {
                    LabeledContent("Timeout požadavku") {
                        Text(formatTimeout(vm.config.requestTimeoutSeconds))
                            .monospacedDigit()
                    }
                }
                .help("Max doba jednoho HTTP požadavku na lokální AI server. Při zaseknutí modelu se požadavek po této době zruší a opakuje.")
            } header: {
                Text("Model a HTTP")
            }
        }
        .formStyle(.grouped)
        .onChange(of: vm.config.maxConcurrentInference) { _, _ in vm.persistAll() }
        .onChange(of: vm.config.maxConcurrentPDFWorkers) { _, _ in vm.persistAll() }
        .onChange(of: vm.config.throttleDelayMs) { _, _ in vm.persistAll() }
        .onChange(of: vm.config.modelContextTokens) { _, _ in vm.persistAll() }
        .onChange(of: vm.config.requestTimeoutSeconds) { _, _ in
            // Rebuild URLSession so the new timeout kicks in on the very next
            // request; URLSessionConfiguration is captured at session creation.
            vm.rebuildLMClient()
            vm.persistAll()
        }
    }

    // MARK: – OCR

    private var ocrTab: some View {
        Form {
            Section {
                Picker("Backend", selection: Binding(
                    get: { vm.config.ocrBackend },
                    set: { vm.setOCRBackend($0) }
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

            Section {
                Toggle(isOn: $vm.config.officeConversionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Konverze office dokumentů (pandoc)")
                        Text("DOCX, ODT, RTF, HTML, EPUB se převedou na text přes pandoc.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $vm.config.popplerPDFTextEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Extrakce PDF textu přes pdftotext (-layout)")
                        Text("Místo PDFKit použije pdftotext; lépe zachová sloupce a tabulky.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $vm.config.spreadsheetConversionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Konverze tabulek (XLSX/XLS) přes csvkit")
                        Text("Tabulky se převedou na CSV přes in2csv.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("pandoc") {
                    Text(pandocStatusText).foregroundStyle(.secondary)
                }
                LabeledContent("pdftotext") {
                    Text(pdftotextStatusText).foregroundStyle(.secondary)
                }
                LabeledContent("in2csv") {
                    Text(in2csvStatusText).foregroundStyle(.secondary)
                }
                LabeledContent("ocrmypdf") {
                    Text(ocrmypdfStatusText).foregroundStyle(.secondary)
                }
                LabeledContent("tesseract") {
                    Text(tesseractStatusText).foregroundStyle(.secondary)
                }
            } header: {
                Text("Lokální nástroje")
            } footer: {
                Text("Nástroje běží lokálně. Pokud nejsou k dispozici, použije se nativní zpracování (PDFKit/Vision).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: vm.config.officeConversionEnabled) { _, _ in vm.persistAll() }
        .onChange(of: vm.config.popplerPDFTextEnabled) { _, _ in vm.persistAll() }
        .onChange(of: vm.config.spreadsheetConversionEnabled) { _, _ in vm.persistAll() }
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
        }
    }

    // MARK: – Cache

    private var cacheTab: some View {
        Form {
            Section {
                Toggle(isOn: $vm.config.bypassInferenceCache) {
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
                Button(role: .destructive) {
                    Task { await vm.clearCache() }
                } label: {
                    Label("Vyčistit cache", systemImage: "trash")
                }
                .help("Smaže dočasné OCR výsledky i uložené LLM odpovědi. Při dalším běhu se vše počítá od nuly.")
            } footer: {
                Text("Pozor: cache je sdílená mezi běhy a nelze ji vrátit zpět.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: vm.config.bypassInferenceCache) { _, _ in vm.persistAll() }
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
