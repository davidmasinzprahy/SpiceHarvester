import SwiftUI

/// Native macOS Settings sheet (Cmd+,). Hosts everything that the user normally
/// configures once and forgets: pipeline performance knobs, request timeout,
/// OCR backend, and inference-cache bypass. Keeping these out of the main
/// window de-clutters the configuration column without losing access.
struct SettingsView: View {
    @Bindable var vm: SHAppViewModel
    @State private var selectedTab: SettingsTab = .performance

    var body: some View {
        VStack(spacing: 0) {
            Text(selectedTab.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.top, 12)

            HStack(spacing: 18) {
                ForEach(SettingsTab.allCases) { tab in
                    settingsTabButton(tab)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider()

            selectedTabContent
        }
        .frame(width: 620, height: 540)
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
                Text("Apple Vision běží lokálně bez AI serveru. oMLX/VLM posílá skenované PDF stránky do vybraného OCR/VLM modelu přes OpenAI-compatible chat completions. Vision→VLM zkusí nejdřív Vision a teprve pokud neuspěje, sáhne po VLM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
}
