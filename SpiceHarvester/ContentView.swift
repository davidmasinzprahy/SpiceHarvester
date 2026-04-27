import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var vm: SHAppViewModel
    /// Owned by the App scene so the Help command (Cmd+?) can flip the same
    /// flag the toolbar button does.
    @Binding var showHelp: Bool

    /// Conflict pending user confirmation. `nil` = no dialog shown. When set,
    /// a `.confirmationDialog` asks the user whether to apply the banner's
    /// suggested change (e.g. switch mode from FAST to CONSOLIDATE). Prevents
    /// one-click destructive actions from analyzer false-positives.
    @State private var pendingConflict: SHParameterConflict?

    /// Honors System Settings → Accessibility → Display → Reduce motion. Used
    /// to skip the header logo wobble for users who explicitly opted out.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var leftCardsAnchorY: CGFloat = 0
    @State private var progressCardY: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // Left: configuration (folders / server / prompt). The prompt
                // editor expands with the window, matching the runtime log.
                VStack(alignment: .leading, spacing: 10) {
                    header
                    leftCardsAlignmentMarker
                    leftConfigurationCards
                        .padding(.top, leftCardsTopAlignmentOffset)
                }
                .padding(14)
                .frame(minWidth: 540, idealWidth: 620)

                // Right: runtime (completion / progress / log). Log expands
                // vertically; nothing nested under another ScrollView so macOS
                // momentum scrolling stays predictable.
                VStack(alignment: .leading, spacing: 10) {
                    runtimeHeaderSpacer
                    if let completion = vm.lastCompletion {
                        completionBanner(completion)
                    }
                    progressStatusCard
                    logCard
                }
                .padding(14)
                .frame(minWidth: 420)
            }
            statusBar
        }
        .frame(minWidth: 980, minHeight: 680)
        .coordinateSpace(name: "contentRoot")
        .onPreferenceChange(LeftCardsAnchorPreferenceKey.self) { leftCardsAnchorY = $0 }
        .onPreferenceChange(ProgressCardYPreferenceKey.self) { progressCardY = $0 }
        .sheet(isPresented: $showHelp) {
            HelpSheet(dismiss: { showHelp = false })
        }
        .background {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    private var leftCardsTopAlignmentOffset: CGFloat {
        guard leftCardsAnchorY > 0, progressCardY > 0 else { return 0 }
        return max(0, progressCardY - leftCardsAnchorY - leftCardsAlignmentSpacingCorrection)
    }

    private var leftCardsAlignmentSpacingCorrection: CGFloat { 10 }

    private var leftCardsAlignmentMarker: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: LeftCardsAnchorPreferenceKey.self,
                    value: proxy.frame(in: .named("contentRoot")).minY
                )
        }
        .frame(height: 0)
        .accessibilityHidden(true)
    }

    private var leftConfigurationCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            foldersCard
            serverCard
            promptsCard
                .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: – Runtime actions

    private var toolbarActions: some View {
        HStack(spacing: 10) {
            if vm.isRunning {
                Button(role: .destructive) {
                    vm.cancelRun()
                } label: {
                    Label("Přerušit", systemImage: "stop.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .help("Přeruší aktuálně běžící úlohu (Cmd+.)")
            } else {
                Button {
                    Task { await vm.runAll() }
                } label: {
                    Label("Spustit", systemImage: "play.fill")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!vm.canRunAll)
                .help(vm.missingRequirementsHint
                      ?? "Spustí kompletní pipeline: předzpracování + extrakci (Cmd+R)")
            }

            Button {
                vm.openOutput()
            } label: {
                Label("Výstup", systemImage: "folder")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!vm.canOpenOutput)
            .help("Otevřít složku výstupu ve Finderu (Cmd+Shift+O)")

            Button {
                showHelp = true
            } label: {
                Label("Nápověda", systemImage: "questionmark.circle")
            }
            .labelStyle(.titleAndIcon)
            .help("Otevřít nápovědu (Cmd+?)")
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 8) {
            if vm.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text(vm.toolbarReadyText)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 13)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Stav: \(vm.toolbarReadyText)")
    }

    // MARK: – Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            headerLogo

            VStack(alignment: .leading, spacing: 0) {
                Text("Spice Harvester")
                    .font(.title2.weight(.bold))
                Text("Nástroj pro hromadné vytěžování dat z dokumentů")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    /// Keeps runtime actions above the Progress card while preserving the right
    /// column's vertical alignment with the configuration column header.
    private var runtimeHeaderSpacer: some View {
        HStack {
            statusIndicator
            Spacer()
            toolbarActions
        }
        .frame(minHeight: 46)
    }

    /// Header logo with a subtle "grinding" wobble while a run is in progress.
    /// Implementation notes:
    /// - `TimelineView(.animation)` is wrapped only while `vm.isRunning && !reduceMotion`.
    ///   When the run ends the wrapper drops out entirely, so there's no
    ///   `repeatForever` animation that could be left half-applied (a known
    ///   SwiftUI footgun on rapid stop/start).
    /// - Sine over time gives a soft, mill-like sway. A triangle wave (ease-in-out
    ///   `repeatForever(autoreverses:)`) would tick like a clock.
    /// - ±7° at 0.55 s period feels like cranking, not vibrating; readable as
    ///   activity at 36×36 pt without screaming for attention.
    /// - Accessibility: respects System Settings → Reduce motion; the icon is
    ///   purely decorative so VoiceOver doesn't need a state-of-motion label.
    private var headerLogo: some View {
        Group {
            if vm.isRunning && !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let angle = sin(t * 2 * .pi / 0.55) * 7
                    logoImage.rotationEffect(.degrees(angle))
                }
            } else {
                logoImage
            }
        }
    }

    private var logoImage: some View {
        Image("AppLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }

    // MARK: – Folders

    private var foldersCard: some View {
        GlassCard(title: "Složky", systemImage: "folder.fill") {
            VStack(spacing: 6) {
                folderRow(icon: "tray.and.arrow.down.fill", label: "Vstup",
                          path: vm.config.inputFolder, action: vm.chooseInputFolder,
                          onDrop: { vm.config.inputFolder = $0; vm.persistAllDebounced() })
                folderRow(icon: "tray.and.arrow.up.fill", label: "Výstup",
                          path: vm.config.outputFolder, action: vm.chooseOutputFolder,
                          onDrop: { vm.config.outputFolder = $0; vm.persistAllDebounced() })
                folderRow(icon: "externaldrive.fill", label: "Cache",
                          path: vm.config.cacheFolder, action: vm.chooseCacheFolder,
                          onDrop: { vm.config.cacheFolder = $0; vm.persistAllDebounced() })
                folderRow(icon: "doc.text.fill", label: "Prompty (.md)",
                          path: vm.config.promptFolder, action: vm.choosePromptFolder,
                          onDrop: { vm.config.promptFolder = $0; vm.persistAllDebounced() })
            }
            // If the user manually replaces the input folder (e.g. via drop),
            // drop the stale in-memory `cachedDocuments` from the previous run.
            .onChange(of: vm.config.inputFolder) { _, _ in
                vm.invalidateCachedDocumentsIfInputChanged()
            }
        }
    }

    private func folderRow(
        icon: String,
        label: String,
        path: String,
        action: @escaping () -> Void,
        onDrop: @escaping (String) -> Void
    ) -> some View {
        let isSelected = !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return HStack(spacing: 8) {
            Label {
                Text(label).fontWeight(.medium)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(isSelected ? Color.green : Color.secondary)
            }
            .frame(width: 130, alignment: .leading)

            // Read-only path field. Drag a folder onto it from Finder to set it
            // without going through the open panel. Truncates the middle so the
            // tail (the actual folder name) stays visible.
            HStack(spacing: 6) {
                Text(isSelected ? path : "—")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .primary : .tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(isSelected ? path : "")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first else { return false }
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
                guard exists, isDir.boolValue else { return false }
                onDrop(first.path)
                return true
            }

            Button {
                action()
            } label: {
                Text(isSelected ? "Změnit" : "Vybrat")
                    .frame(minWidth: 64)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .help(isSelected ? "Vybrat jinou složku" : "Vybrat složku ve Finderu")
        }
    }

    // MARK: – Server / model

    private var serverCard: some View {
        GlassCard(title: "Server a model", systemImage: "server.rack") {
            VStack(alignment: .leading, spacing: 10) {
                serverPickerRow

                if vm.servers.indices.contains(vm.selectedServerIndex) {
                    serverDetailFields
                }

                Divider().opacity(0.4)

                modelPickersGrid

                Divider().opacity(0.4)

                modeRow
            }
            .onChange(of: vm.config.extractionMode) { _, _ in vm.persistAll() }
        }
    }

    private var serverPickerRow: some View {
        HStack(spacing: 6) {
            Picker("Server", selection: Binding(
                get: { vm.selectedServerIndex },
                set: { newValue in
                    // Reset the "Ověřeno" state whenever the user picks a
                    // different server, even before the index setter fires.
                    if newValue != vm.selectedServerIndex {
                        vm.invalidateServerVerification()
                    }
                    vm.selectedServerIndex = newValue
                }
            )) {
                ForEach(Array(vm.servers.enumerated()), id: \.element.id) { idx, server in
                    Text(server.name).tag(idx)
                }
            }
            .labelsHidden()

            Button { vm.addServer() } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .tint(.blue)
            .help("Přidat LM Studio server")
            .accessibilityLabel("Přidat server")

            Button { vm.addMLXServer() } label: {
                Label("MLX", systemImage: "apple.logo")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Přidat MLX server na http://localhost:8000/v1")
            .accessibilityLabel("Přidat MLX server")

            Button { vm.removeSelectedServer() } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .tint(.blue)
            .help("Odebrat vybraný server")
            .accessibilityLabel("Odebrat vybraný server")

            Spacer(minLength: 6)

            if !vm.isRunning {
                verifyServerButton
            }
        }
    }

    private var serverDetailFields: some View {
        VStack(spacing: 6) {
            TextField("Název serveru", text: Binding(
                get: { vm.servers[vm.selectedServerIndex].name },
                set: { vm.servers[vm.selectedServerIndex].name = $0; vm.persistAllDebounced() }
            ))
            .textFieldStyle(.roundedBorder)

            TextField("Base URL (např. http://localhost:1234/v1 nebo http://localhost:8000/v1)", text: Binding(
                get: { vm.servers[vm.selectedServerIndex].baseURL },
                set: {
                    vm.servers[vm.selectedServerIndex].baseURL = $0
                    vm.serverConnectionDetailsChanged()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

            SecureField("API Key (volitelné)", text: Binding(
                get: { vm.servers[vm.selectedServerIndex].apiKey },
                set: {
                    vm.servers[vm.selectedServerIndex].apiKey = $0
                    vm.serverConnectionDetailsChanged()
                }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private var modelPickersGrid: some View {
        // 2×2 grid scales down better than two HStacks at the narrower
        // configuration column width, and keeps related pickers paired
        // visually (Inference + Embedding for retrieval, Reranker + OCR for
        // post-processing).
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                modelPicker(title: "Inference",
                            selection: Binding(
                                get: { vm.config.selectedInferenceModel },
                                set: { vm.setInferenceModel($0) }
                            ),
                            placeholder: "-- vyber --")
                modelPicker(title: "Embedding",
                            selection: Binding(
                                get: { vm.config.selectedEmbeddingModel },
                                set: { vm.setEmbeddingModel($0) }
                            ),
                            placeholder: "-- vypnuto --")
            }
            GridRow {
                modelPicker(title: "Reranker",
                            selection: Binding(
                                get: { vm.config.selectedRerankerModel },
                                set: { vm.setRerankerModel($0) }
                            ),
                            placeholder: "-- vypnuto --")
                modelPicker(title: "OCR/VLM",
                            selection: Binding(
                                get: { vm.config.selectedOCRModel },
                                set: { vm.setOCRModel($0) }
                            ),
                            placeholder: "-- vyber pro VLM --")
            }
        }
    }

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Režim extrakce")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: modeHintIcon)
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Spacer()
                Text("Pokročilá nastavení v Předvolbách (Cmd+,)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Picker("Režim extrakce", selection: $vm.config.extractionMode) {
                ForEach(SHExtractionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Single-line caption that explains the active mode without making
            // the user hover over the hint icon.
            Text(modeHintText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var verifyServerButton: some View {
        if vm.isSelectedServerVerified {
            Button {
                Task { await vm.verifyServer() }
            } label: {
                Label("Ověřeno", systemImage: "checkmark.seal.fill")
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .help("Server byl úspěšně ověřen v této session. Klikni pro nové ověření.")
        } else {
            Button {
                Task { await vm.verifyServer() }
            } label: {
                Label("Ověřit", systemImage: "checkmark.seal")
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(!vm.canVerifyServer)
            .help("Zkontrolovat spojení a načíst seznam modelů")
        }
    }

    private var modeHintIcon: String {
        switch vm.config.extractionMode {
        case .fast: return "bolt.fill"
        case .search: return "magnifyingglass"
        case .consolidate: return "square.stack.3d.up.fill"
        }
    }

    private var modeHintText: String {
        switch vm.config.extractionMode {
        case .fast:
            return "FAST – jeden požadavek na každý dokument, bez embeddingů."
        case .search:
            return "SEARCH – per-dokument inference s RAG (relevantní chunky přes embedding model)."
        case .consolidate:
            return "CONSOLIDATE – všechny dokumenty v jednom požadavku, jedna agregovaná odpověď. Vyžaduje model s velkým kontextem."
        }
    }

    private func modelPicker(title: String, selection: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                Text(placeholder).tag("")
                ForEach(vm.availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
        }
    }

    // MARK: – Prompts

    private var promptsCard: some View {
        GlassCard(title: "Prompt", systemImage: "text.quote") {
            VStack(alignment: .leading, spacing: 8) {
                promptToolRow

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $vm.config.currentPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 160, maxHeight: .infinity)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )

                    if vm.config.currentPrompt.isEmpty {
                        Text("Zadej prompt…")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxHeight: .infinity)

                // Conflict banners: shows a subtle notice whenever the current config
                // disagrees with what the prompt seems to want. One-click to apply.
                ForEach(Array(vm.parameterConflicts.enumerated()), id: \.offset) { _, conflict in
                    conflictBanner(conflict)
                }
            }
            .onChange(of: vm.selectedPromptFile) { _, newValue in
                if let newValue {
                    vm.loadPromptFile(newValue)
                }
            }
            .onChange(of: vm.config.currentPrompt) { _, _ in
                vm.persistAllDebounced()
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var promptToolRow: some View {
        HStack(spacing: 8) {
            Button {
                vm.reloadPromptFiles()
            } label: {
                Label("Načíst", systemImage: "arrow.down.doc.fill")
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(!vm.canLoadPrompts)
            .help("Načte .md prompty ze složky Prompty")

            if !vm.availablePromptFiles.isEmpty {
                Picker("Uložené prompty", selection: $vm.selectedPromptFile) {
                    Text("— vyber —").tag(URL?.none)
                    ForEach(vm.availablePromptFiles, id: \.self) { url in
                        Text(url.deletingPathExtension().lastPathComponent)
                            .tag(Optional(url))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            } else {
                Text("Ve složce zatím žádné .md")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            HStack(spacing: 4) {
                Button {
                    vm.applyPromptThinkingMode(.noThinking)
                } label: {
                    Label("nothink", systemImage: "bolt.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(vm.promptThinkingMode == .noThinking ? .green : .blue)
                .help("Vloží do promptu /no_think. U podporovaných modelů zrychlí odpověď vypnutím thinking režimu.")

                Button {
                    vm.applyPromptThinkingMode(.thinking)
                } label: {
                    Label("think", systemImage: "brain.head.profile")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(vm.promptThinkingMode == .thinking ? .orange : .blue)
                .help("Vloží do promptu /think. U podporovaných modelů zapne thinking režim.")
            }

            Spacer()

            if !vm.config.currentPrompt.isEmpty {
                Button {
                    vm.clearPrompt()
                } label: {
                    Label("Vymazat", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .tint(.blue)
            }
        }
    }

    @ViewBuilder
    private func conflictBanner(_ conflict: SHParameterConflict) -> some View {
        let (icon, tint) = bannerStyle(for: conflict)

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(conflict.title)
                    .font(.footnote.weight(.semibold))
                Text(conflict.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if let actionLabel = conflict.actionLabel {
                Button(actionLabel) {
                    // Don't apply directly – ask first. Conflict detection is a
                    // heuristic (keyword match on the prompt text) and may fire
                    // false positives. Mode switching is destructive (changes
                    // the pipeline's behavior silently for the next run), so
                    // requiring a confirm click keeps users in control.
                    pendingConflict = conflict
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.blue)
            }
        }
        .padding(8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
        )
        .confirmationDialog(
            pendingConflict?.title ?? "",
            isPresented: Binding(
                get: { pendingConflict != nil },
                set: { if !$0 { pendingConflict = nil } }
            ),
            presenting: pendingConflict
        ) { conflict in
            if let actionLabel = conflict.actionLabel {
                Button(actionLabel) {
                    vm.apply(conflict)
                    pendingConflict = nil
                }
            }
            Button("Zrušit", role: .cancel) { pendingConflict = nil }
        } message: { conflict in
            Text(conflict.message)
        }
    }

    private func bannerStyle(for conflict: SHParameterConflict) -> (icon: String, tint: Color) {
        switch conflict {
        case .modeMismatch:
            return ("lightbulb.fill", .yellow)
        case .searchModeWithoutEmbeddingModel:
            return ("exclamationmark.triangle.fill", .orange)
        case .consolidateIgnoresConcurrency:
            return ("info.circle.fill", .blue)
        }
    }

    // MARK: – Completion banner (right column top)

    /// Persistent acknowledge row shown after a run finishes. Replaces the old
    /// completionButton in the action card – with the toolbar driving Run/Stop,
    /// the completion needs its own visible spot in the runtime column.
    @ViewBuilder
    private func completionBanner(_ completion: SHRunCompletion) -> some View {
        let (title, icon, tint): (String, String, Color) = {
            switch completion {
            case .success:   return ("Hotovo",    "checkmark.circle.fill",         .green)
            case .cancelled: return ("Přerušeno", "xmark.circle.fill",             .gray)
            case .failed:    return ("Selhalo",   "exclamationmark.triangle.fill", .red)
            }
        }()

        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Potvrdit") {
                vm.acknowledgeCompletion()
            }
            .buttonStyle(.bordered)
            .tint(.blue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: – Progress

    /// Unified progress card. Replaces the old `Progress` + `Výkon` split – the
    /// user cares about three things during a run: what phase they're in as a
    /// percentage, how long it will take, and whether the pipeline is stuck.
    /// Everything else (benchmark breakdown, throughput, counter dump) was noise.
    private var progressStatusCard: some View {
        GlassCard(title: "Průběh", systemImage: "chart.bar.fill") {
            switch vm.progressState.phase {
            case .idle:
                progressIdleContent
            case .preprocessing, .extraction:
                // Live ticker so the "x s bez pokroku" / elapsed / ETA fields
                // stay current even when no counter has moved yet.
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    progressActiveContent(now: context.date)
                }
            case .finished:
                progressFinishedContent
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: ProgressCardYPreferenceKey.self,
                        value: proxy.frame(in: .named("contentRoot")).minY
                    )
            }
        }
    }

    private var progressIdleContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("Připraveno – spusťte zpracování tlačítkem „Spustit\" v horní liště (Cmd+R).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func progressActiveContent(now: Date) -> some View {
        let state = vm.progressState
        let percent = state.currentPhasePercent
        let health = state.health(now: now)
        let elapsed = state.elapsedSeconds(now: now)
        let silent = state.secondsSinceLastProgress(now: now)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: phaseIcon(state.phase))
                    .font(.footnote)
                    .foregroundStyle(.blue)
                    .symbolRenderingMode(.hierarchical)
                Text(state.phaseTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.0f %%", percent * 100))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.blue)
            }

            ProgressView(value: percent)
                .tint(.blue)

            HStack {
                Label(state.currentPhaseCountText, systemImage: "doc.on.doc")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Label("Uplynulo: \(humanDuration(elapsed))",
                      systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.35)

            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Zbývá:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.etaHuman)
                    .font(.caption.monospacedDigit().weight(.medium))
                Spacer()
            }

            healthRow(health: health, silent: silent)
        }
    }

    private var progressFinishedContent: some View {
        let state = vm.progressState
        let elapsed = state.elapsedSeconds()
        let completion = vm.lastCompletion
        let appearance: (String, Color, String) = {
            switch completion {
            case .success?:
                return ("checkmark.seal.fill", .green, "Hotovo")
            case .cancelled?:
                return ("xmark.circle.fill", .secondary, "Přerušeno")
            case .failed?:
                return ("exclamationmark.triangle.fill", .red, "Selhalo")
            case nil:
                return ("stop.circle.fill", .secondary, "Ukončeno")
            }
        }()
        let summary: String = {
            if completion == .success {
                let total = state.counters.foundPDFs
                return "\(total) / \(total) dokumentů · trvalo \(humanDuration(elapsed))"
            }
            if state.extractionProgressTotal > 0,
               state.extractionProgressTotal != state.counters.foundPDFs {
                return "\(state.extractionProgressCompleted) / \(state.extractionProgressTotal) LM kroků · trvalo \(humanDuration(elapsed))"
            }
            return "\(state.counters.completed) / \(state.counters.foundPDFs) dokumentů · trvalo \(humanDuration(elapsed))"
        }()

        return HStack(spacing: 10) {
            Image(systemName: appearance.0)
                .font(.title3)
                .foregroundStyle(appearance.1)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(appearance.2)
                    .font(.subheadline.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    private func healthRow(health: SHProgressHealth, silent: Double) -> some View {
        let (icon, color, text): (String, Color, String) = {
            switch health {
            case .idle:
                return ("circle", .secondary, "")
            case .starting:
                return ("hourglass.circle.fill", .blue,
                        "Inicializace – čekám na první dokument…")
            case .ok:
                let s = Int(silent)
                let note = s < 2
                    ? "Vše v pořádku · aktualizuje se právě teď"
                    : "Vše v pořádku · poslední pokrok před \(s) s"
                return ("checkmark.circle.fill", .green, note)
            case .stuck:
                if silent == .infinity {
                    return ("exclamationmark.triangle.fill", .orange,
                            "Bez pokroku – zkontrolujte server v LM Studiu")
                }
                let s = Int(silent)
                return ("exclamationmark.triangle.fill", .orange,
                        "Zdá se, že je zpracování pozastavené (\(s) s bez pokroku)")
            case .finished:
                return ("checkmark.seal.fill", .green, "Dokončeno")
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .symbolRenderingMode(.hierarchical)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func phaseIcon(_ phase: SHProgressPhase) -> String {
        switch phase {
        case .idle:          return "pause.circle"
        case .preprocessing: return "doc.text.magnifyingglass"
        case .extraction:    return "brain"
        case .finished:      return "checkmark.seal"
        }
    }

    /// Human-readable seconds → `"12 s"`, `"3 min 05 s"`, `"1 h 12 min"`.
    private func humanDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        let ss = s % 60
        if m < 60 { return ss == 0 ? "\(m) min" : String(format: "%d min %02d s", m, ss) }
        let h = m / 60
        let mm = m % 60
        return "\(h) h \(mm) min"
    }

    // MARK: – Log

    private var logCard: some View {
        GlassCard(title: "Log", systemImage: "text.alignleft") {
            // logText mirrors the on-disk log only at phase boundaries (after
            // preprocessing or extraction finishes). During a long run the user
            // needs a manual refresh to peek at the live tail.
            HStack(spacing: 6) {
                Spacer()
                Button {
                    Task { await vm.refreshLog() }
                } label: {
                    Label("Obnovit", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .tint(.blue)
                .controlSize(.small)
                .help("Načíst aktuální obsah logu z disku")
            }

            // Plain selectable text in a ScrollView (instead of a read-only TextEditor,
            // which recreates its binding on every update and doesn't auto-scroll).
            // The right column is no longer wrapped in an outer ScrollView, so this
            // scroll view owns its momentum without macOS gesture conflicts.
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.logText.isEmpty ? " " : vm.logText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                        .id("logBottom")
                }
                .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 200, maxHeight: .infinity)
                .onChange(of: vm.logText) { _, _ in
                    // Scroll to the end whenever the log grows so the user always
                    // sees the most recent activity.
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: – Status bar

    private var statusBar: some View {
        ZStack {
            Color.clear
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if vm.isRunning {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel("Probíhá zpracování")
                    } else {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Připraveno")
                    }
                }
                .frame(width: 12, height: 12)
                Text(vm.statusText)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Stav: \(vm.statusText)")
                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
        .background(.thinMaterial)
        .overlay(Divider(), alignment: .top)
    }
}

private struct LeftCardsAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        guard next > 0 else { return }
        value = value == 0 ? next : min(value, next)
    }
}

private struct ProgressCardYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        guard next > 0 else { return }
        value = value == 0 ? next : min(value, next)
    }
}
