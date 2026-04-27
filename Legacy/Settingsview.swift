//
//  Settingsview.swift
//  SpiceHarvester
//
//  Created by David Mašín on 27.06.2025.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearanceMode") private var appearanceModeRawValue = AppearanceMode.system.rawValue
    @AppStorage("lmStudioURL") private var lmStudioURL: String = "http://localhost:1234/v1/chat/completions"
    @AppStorage("lmStudioAPIToken") private var lmStudioAPIToken: String = ""
    @AppStorage("recentLMStudioURLs") private var recentLMStudioURLsRaw: String = ""
    @AppStorage("qdrantURL") private var qdrantURL: String = "http://localhost:6333"
    @AppStorage("qdrantAPIKey") private var qdrantAPIKey: String = ""
    @AppStorage("autoManageRAGPipeline") private var autoManageRAGPipeline: Bool = true
    @AppStorage("validateAgainstQdrant") private var validateAgainstQdrant: Bool = true
    @AppStorage("strictPipelineManifestValidation") private var strictPipelineManifestValidation: Bool = true
    @AppStorage("openDataLoaderPath") private var openDataLoaderPath: String = ""
    @AppStorage("useEmbeddingDedup") private var useEmbeddingDedup: Bool = false
    @AppStorage("embeddingModelName") private var embeddingModelName: String = "bge-m3"
    @State private var lmStudioStatus: String = "Připraveno k testu spojení."
    @State private var testingLMStudio = false
    @State private var odlStatus: String = ""
    @State private var testingODL = false

    private static let maxRecentURLs = 5

    private var recentLMStudioURLs: [String] {
        recentLMStudioURLsRaw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func addRecentLMStudioURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentLMStudioURLs.filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        if list.count > Self.maxRecentURLs {
            list = Array(list.prefix(Self.maxRecentURLs))
        }
        recentLMStudioURLsRaw = list.joined(separator: "\n")
    }

    private func removeRecentLMStudioURL(_ url: String) {
        let list = recentLMStudioURLs.filter { $0 != url }
        recentLMStudioURLsRaw = list.joined(separator: "\n")
    }

    private var palette: GlassPalette {
        GlassPalette.forScheme(colorScheme)
    }

    private var appearanceMode: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceModeRawValue) ?? .system },
            set: { appearanceModeRawValue = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            GlassBackground(palette: palette)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Nastavení")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.textPrimary)

                    GlassSection(
                        title: "LM Studio",
                        subtitle: "API adresa je nově uložená jen tady. Hlavní obrazovka zůstává jednodušší.",
                        palette: palette
                    ) {
                        HStack(spacing: 8) {
                            TextField("http://localhost:1234/v1/chat/completions", text: $lmStudioURL)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(inputBackground)

                            if !recentLMStudioURLs.isEmpty {
                                Menu {
                                    ForEach(recentLMStudioURLs, id: \.self) { url in
                                        Button {
                                            lmStudioURL = url
                                        } label: {
                                            HStack {
                                                Text(url)
                                                if url == lmStudioURL {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }

                                    Divider()

                                    Menu("Odstranit") {
                                        ForEach(recentLMStudioURLs, id: \.self) { url in
                                            Button {
                                                removeRecentLMStudioURL(url)
                                            } label: {
                                                HStack {
                                                    Image(systemName: "xmark.circle")
                                                    Text(url)
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .menuStyle(.borderlessButton)
                                .help("Posledních \(Self.maxRecentURLs) úspěšných připojení")
                                .fixedSize()
                            }
                        }

                        SecureField("LM Studio API token (volitelné)", text: $lmStudioAPIToken)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(inputBackground)

                        HStack(spacing: 10) {
                            Button(testingLMStudio ? "Testuji..." : "Test připojení") {
                                testLMStudioConnection()
                            }
                            .disabled(testingLMStudio || lmStudioURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .buttonStyle(.bordered)

                            Button("Otevřít API adresu") {
                                openLMStudioURL()
                            }
                            .buttonStyle(.bordered)
                            .disabled(lmStudioURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        Text(lmStudioStatus)
                            .font(.footnote)
                            .foregroundStyle(palette.textSecondary)
                    }

                    GlassSection(
                        title: "RAG / Qdrant",
                        subtitle: "Skryté infrastrukturní nastavení pro automatický běh konfigurace.",
                        palette: palette
                    ) {
                        settingsToggle("Automaticky spravovat konfiguraci RAG", isOn: $autoManageRAGPipeline)
                        settingsToggle("Validovat Qdrant před během", isOn: $validateAgainstQdrant)
                        settingsToggle("Vyžadovat manifest konfigurace", isOn: $strictPipelineManifestValidation)

                        TextField("Qdrant URL", text: $qdrantURL)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(inputBackground)

                        SecureField("Qdrant API klíč (volitelné)", text: $qdrantAPIKey)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(inputBackground)

                        Text("Běžný uživatel už nic z toho neřeší na hlavní obrazovce. Aplikace si sama připraví kolekci i manifest podle modelu z LM Studia.")
                            .font(.footnote)
                            .foregroundStyle(palette.textSecondary)
                    }

                    GlassSection(
                        title: "OpenDataLoader PDF",
                        subtitle: "Volitelný backend pro přesnější extrakci textu z PDF. Vyžaduje: pip install opendataloader-pdf",
                        palette: palette
                    ) {
                        TextField("Auto-detect (ponech prázdné)", text: $openDataLoaderPath)
                            .textFieldStyle(.roundedBorder)

                        if !odlStatus.isEmpty {
                            Text(odlStatus)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(odlStatus.contains("OK") ? .green : palette.textSecondary)
                        }

                        Button("Otestovat OpenDataLoader") {
                            testOpenDataLoader()
                        }
                        .disabled(testingODL)
                    }

                    GlassSection(
                        title: "Embedding deduplikace",
                        subtitle: "Detekce near-duplicate bloků napříč dávkou. Vyžaduje embedding model v LM Studiu (např. bge-m3, qwen3-embedding-0.6b).",
                        palette: palette
                    ) {
                        Toggle("Zapnout embedding deduplikaci", isOn: $useEmbeddingDedup)

                        TextField("Název embedding modelu (např. bge-m3)", text: $embeddingModelName)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!useEmbeddingDedup)

                        Text("Pokud profil podporuje dedup a toto je zapnuto, bloky se před odesláním na LLM embedují a near-duplicates se přeskočí. Práh podobnosti je per-profil.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(palette.textSecondary)
                    }

                    GlassSection(
                        title: "Režim zobrazení",
                        subtitle: "Vyber jeden režim. Aktivní volba je vždy jen jedna.",
                        palette: palette
                    ) {
                        VStack(spacing: 10) {
                            ForEach(AppearanceMode.allCases) { mode in
                                AppearanceModeOptionButton(
                                    mode: mode,
                                    isSelected: appearanceMode.wrappedValue == mode,
                                    palette: palette
                                ) {
                                    appearanceMode.wrappedValue = mode
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity)
        .frame(minHeight: 400, maxHeight: .infinity, alignment: .top)
    }

    private func testOpenDataLoader() {
        testingODL = true
        odlStatus = "Hledám opendataloader-pdf..."

        DispatchQueue.global(qos: .userInitiated).async {
            let resolvedPath = Self.resolveODLPath(explicit: openDataLoaderPath)
            guard let path = resolvedPath else {
                DispatchQueue.main.async {
                    odlStatus = "Nenalezeno. Nainstaluj: pip install opendataloader-pdf"
                    testingODL = false
                }
                return
            }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = ["--version"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                DispatchQueue.main.async {
                    odlStatus = task.terminationStatus == 0
                        ? "OK — \(version) (\(path))"
                        : "Chyba při spuštění: exit \(task.terminationStatus)"
                    testingODL = false
                }
            } catch {
                DispatchQueue.main.async {
                    odlStatus = "Nepodařilo se spustit: \(error.localizedDescription)"
                    testingODL = false
                }
            }
        }
    }

    static func resolveODLPath(explicit: String) -> String? {
        let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }

        // Auto-detect via common paths
        let candidates = [
            "/usr/local/bin/opendataloader-pdf",
            "/opt/homebrew/bin/opendataloader-pdf",
            "\(NSHomeDirectory())/.local/bin/opendataloader-pdf",
            "\(NSHomeDirectory())/Library/Python/3.11/bin/opendataloader-pdf",
            "\(NSHomeDirectory())/Library/Python/3.12/bin/opendataloader-pdf",
            "\(NSHomeDirectory())/Library/Python/3.13/bin/opendataloader-pdf",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try `which`
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["opendataloader-pdf"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func testLMStudioConnection() {
        let endpoint = lmStudioURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else {
            lmStudioStatus = "Zadej nejdřív URL LM Studia."
            return
        }

        let diagnostics = DiagnosticsService()
        guard let url = diagnostics.modelListURL(from: endpoint) else {
            lmStudioStatus = "Neplatná URL adresa LM Studia."
            return
        }

        testingLMStudio = true
        lmStudioStatus = "Ověřuji spojení s LM Studiem..."

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedToken = lmStudioAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                testingLMStudio = false

                if let error {
                    lmStudioStatus = "Spojení selhalo: \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    lmStudioStatus = "LM Studio nevrátilo platnou HTTP odpověď."
                    return
                }

                guard httpResponse.statusCode == 200 else {
                    let diagnostics = DiagnosticsService()
                    lmStudioStatus = diagnostics.lmStudioEndpointIssueMessage(statusCode: httpResponse.statusCode)
                    return
                }

                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["data"] as? [[String: Any]],
                   let firstModel = models.first?["id"] as? String {
                    lmStudioStatus = "Spojení OK. První nalezený model: \(firstModel)"
                    addRecentLMStudioURL(endpoint)
                } else {
                    lmStudioStatus = "Spojení OK, ale nepodařilo se přečíst seznam modelů."
                    addRecentLMStudioURL(endpoint)
                }
            }
        }.resume()
    }

    private func openLMStudioURL() {
        guard let url = URL(string: lmStudioURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.28))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
    }
}
