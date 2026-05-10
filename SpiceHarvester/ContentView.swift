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
    /// Optional case-insensitive substring filter applied to the log card. Empty
    /// = show all lines. Lives on the view (not the view model) because filtering
    /// is purely a presentation concern — the on-disk log is unchanged.
    @State private var logFilter: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // Left: configuration + run controls. Configuration cards stack
                // top-down; the toolbar (status + Spustit/Výstup/Nápověda) sits
                // at the bottom so "set things up here, then run from here"
                // reads as one visually grouped column.
                VStack(alignment: .leading, spacing: 10) {
                    header
                    leftConfigurationCards
                    Divider().opacity(0.4)
                    runtimeHeaderSpacer
                }
                .padding(14)
                .frame(minWidth: 460, idealWidth: 540)

                // Right: pure workspace + monitoring. The Prompt editor owns
                // the prime vertical space; banners stack right above it and
                // Progress + Log sit below. With Run/Stop moved to the left
                // column, this column has zero chrome — just content.
                VStack(alignment: .leading, spacing: 10) {
                    notificationStack
                    promptsCard
                        .frame(minHeight: 240, maxHeight: .infinity)
                    progressStatusCard
                    logCard
                }
                .padding(14)
                .frame(minWidth: 480)
            }
            statusBar
        }
        .frame(minWidth: 940, minHeight: 660)
        .coordinateSpace(name: "contentRoot")
        .onAppear { vm.refreshInputFolderStats() }
        .onChange(of: vm.config.inputFolder) { _, _ in
            vm.refreshInputFolderStats()
        }
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

    /// Right-column notification stack: completion banner first (post-run), then
    /// any active config conflicts. Both used to live in different places — the
    /// completion in the right column, conflicts under the prompt editor — which
    /// split the user's attention. Grouping them under the runtime header keeps
    /// "things I need to act on" in one place and lets the prompt editor own its
    /// full vertical room.
    @ViewBuilder
    private var notificationStack: some View {
        if vm.lastCompletion != nil || !vm.parameterConflicts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let completion = vm.lastCompletion {
                    completionBanner(completion)
                }
                ForEach(Array(vm.parameterConflicts.enumerated()), id: \.offset) { _, conflict in
                    conflictBanner(conflict)
                }
            }
        }
    }

    private var leftConfigurationCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !vm.isSetupComplete {
                onboardingCard
            }
            foldersCard
            serverCard
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Onboarding banner shown above the configuration cards while any of the
    /// Compact horizontal onboarding indicator. Shown only while at least one
    /// of the four setup steps is missing. The step labels live as a single
    /// row of "chips" so the banner takes one card-row of vertical space
    /// instead of four. The next-step hint underneath is contextual: it
    /// surfaces the first missing step's tip, guiding the user to act, not
    /// just listing all steps statically.
    private var onboardingCard: some View {
        let steps = vm.setupSteps
        let doneCount = steps.filter(\.isDone).count
        let nextStep = steps.first(where: { !$0.isDone })

        return GlassCard(title: "Začni tady", systemImage: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        onboardingChip(step: step, index: index + 1)
                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(step.isDone ? Color.green.opacity(0.45) : Color.primary.opacity(0.10))
                                .frame(height: 1)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                if let nextStep {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.forward.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .symbolRenderingMode(.hierarchical)
                        Text("Další krok – **\(nextStep.title)**: \(nextStep.hint)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(doneCount) / \(steps.count)")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// One step in the horizontal onboarding strip. Compact "chip" with the
    /// numeric index (or check) and an abbreviated label so the whole row
    /// fits even at the narrowest configured column width (460 pt).
    private func onboardingChip(step: SHSetupStep, index: Int) -> some View {
        let tint: Color = step.isDone ? .green : .secondary
        let shortLabel: String = {
            switch step.id {
            case "input":  return "Vstup"
            case "output": return "Výstup"
            case "server": return "Server"
            case "prompt": return "Prompt"
            default:       return step.title
            }
        }()
        return HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(step.isDone ? Color.green : Color.primary.opacity(0.06))
                    .frame(width: 18, height: 18)
                Circle()
                    .strokeBorder(step.isDone ? Color.green : Color.primary.opacity(0.20), lineWidth: 0.8)
                    .frame(width: 18, height: 18)
                if step.isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(shortLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(step.isDone ? .secondary : .primary)
                .lineLimit(1)
                .fixedSize()
        }
        .help(step.title + " – " + step.hint)
        .accessibilityLabel("\(step.title): \(step.isDone ? "hotovo" : "ještě nehotovo")")
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

    /// Bottom-of-left-column run bar: status indicator on the left, the action
    /// trio (Spustit / Výstup / Nápověda) on the right. The whole row is
    /// pinned to the bottom of the configuration column so "set up here, run
    /// here" forms a single visual flow without scattering controls across
    /// the window. Name kept for git-blame continuity even though the row
    /// is no longer a "header spacer".
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
                VStack(alignment: .leading, spacing: 2) {
                    folderRow(icon: "tray.and.arrow.down.fill", label: "Vstup",
                              path: vm.config.inputFolder, action: vm.chooseInputFolder,
                              onDrop: { vm.config.inputFolder = $0; vm.persistAllDebounced() })
                    if let chip = vm.inputFolderChipLabel {
                        inputFolderChip(chip)
                    }
                }
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

    /// Quick chip under the Vstup row showing the recursive PDF count + total
    /// size. Aligned under the path display (130 pt label width + 8 pt label
    /// gap), so it visually attaches to the path it describes. Hidden when no
    /// scan has run yet — the view's `.onChange(of: inputFolder)` triggers a
    /// fresh scan as soon as the user picks/drops a folder.
    private func inputFolderChip(_ label: String) -> some View {
        let isEmpty = vm.inputFolderPdfCount == 0
        let tint: Color = isEmpty ? .orange : .blue
        let icon = isEmpty ? "exclamationmark.triangle.fill" : "doc.fill"
        return HStack(spacing: 6) {
            Spacer().frame(width: 138)
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isEmpty ? tint : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
            .help(isEmpty
                  ? "Ve vstupní složce nejsou žádné PDF — vyber jinou složku nebo do této přidej PDF."
                  : "Recursivní scan vstupní složky.")
            Spacer()
        }
        .padding(.leading, 0)
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
            .help(Text(verbatim: "Přidat MLX server na http://localhost:8000/v1"))
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
            return "FAST – jeden požadavek na každý dokument, bez embeddingů. Vhodné pro krátké zprávy, lab. výsledky a dokumenty, které se vejdou do kontextu modelu."
        case .search:
            return "SEARCH – per-dokument inference s RAG (relevantní chunky přes embedding model). Vhodné pro dlouhé dokumenty, kde stačí pár klíčových pasáží — smlouvy, posudky, technické zprávy."
        case .consolidate:
            return "CONSOLIDATE – všechny dokumenty v jednom požadavku, jedna agregovaná odpověď. Vhodné pro dedupování / shrnutí napříč dávkou. Vyžaduje model s velkým kontextem."
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
    }

    private var progressIdleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            if let lastRunRow = lastRunIdleSummary {
                Divider().opacity(0.35)
                lastRunRow
            }
        }
    }

    /// Compact "Poslední běh" row shown in the idle Progress card. Combines the
    /// per-document baseline persisted from the previous run with the live PDF
    /// count from `inputFolderPdfCount` to predict the next-run duration before
    /// the user even presses Run. Hidden when there's no history (first run) or
    /// no input folder is selected yet.
    private var lastRunIdleSummary: AnyView? {
        guard let perDocMs = vm.estimatedPerDocumentMs else { return nil }
        let perDocSeconds = perDocMs / 1000.0

        let count: Int? = vm.inputFolderPdfCount
        let predicted: Double? = {
            guard let count, count > 0 else { return nil }
            return perDocSeconds * Double(count)
        }()

        // Use the sub-second-aware formatter — `humanDuration` rounds anything
        // under 0.5 s to "0 s", which produced the misleading "ø 0 s/dok"
        // when the previous run was all-cache-hit (a few ms per document).
        let perDocLabel = humanDurationDetailed(perDocSeconds)
        let predictedLabel = predicted.map { "≈ \(humanDuration($0))" } ?? "—"
        let countLabel = count.map { "\($0) dok" } ?? "—"

        return AnyView(
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.blue)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Předchozí běh")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Label("⌀ \(perDocLabel)/dok", systemImage: "speedometer")
                            .labelStyle(.titleOnly)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Label("Vstup: \(countLabel)", systemImage: "doc.on.doc")
                            .labelStyle(.titleOnly)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Label("Odhad: \(predictedLabel)", systemImage: "hourglass")
                            .labelStyle(.titleOnly)
                            .font(.caption.monospacedDigit().weight(.medium))
                    }
                }
                Spacer()
            }
        )
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

            currentlyProcessingRow(state: state)

            healthRow(health: health, silent: silent)
        }
    }

    /// Per-item activity line under the ETA row. Lists up to ~3 file names that
    /// are *currently* in flight (FAST/SEARCH runs N concurrent inferences) and
    /// — when nothing is in flight at this exact moment, e.g. between throttle
    /// pauses — falls back to "naposledy: X" so the user always sees forward
    /// motion. Hidden when the pipeline doesn't expose per-item events
    /// (CONSOLIDATE single request).
    @ViewBuilder
    private func currentlyProcessingRow(state: SHProgressViewState) -> some View {
        let inflight = state.currentlyProcessing
        let last = state.lastFinishedItem

        if inflight.isEmpty && last == nil {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: inflight.isEmpty ? "checkmark.circle" : "gearshape.2.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .symbolRenderingMode(.hierarchical)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    if !inflight.isEmpty {
                        Text(currentlyProcessingLabel(inflight))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    if let last, last != inflight.first {
                        Text("Naposledy: \(last)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
            }
        }
    }

    private func currentlyProcessingLabel(_ items: [String]) -> String {
        guard !items.isEmpty else { return "" }
        if items.count == 1 {
            return "Probíhá: \(items[0])"
        }
        let head = items.prefix(2).joined(separator: ", ")
        let extra = items.count - 2
        return extra > 0
            ? "Probíhá: \(head) (+\(extra))"
            : "Probíhá: \(head)"
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

    /// Variant of `humanDuration` that preserves sub-second resolution. Used
    /// for the per-document baseline ("ø 0,4 s/dok") where rounding to 0
    /// would be actively misleading on cache-only runs. Falls back to the
    /// minute-formatter once we cross 1 s, so the two formatters agree on
    /// values where it matters (long runs).
    private func humanDurationDetailed(_ seconds: Double) -> String {
        if seconds < 0.001 { return "<1 ms" }
        if seconds < 1 {
            return String(format: "%.0f ms", seconds * 1000)
        }
        if seconds < 10 {
            // 1–10 s: one decimal so "ø 1,4 s/dok" reads naturally.
            return String(format: "%.1f s", seconds)
        }
        return humanDuration(seconds)
    }

    // MARK: – Log

    private var logCard: some View {
        GlassCard(title: "Log", systemImage: "text.alignleft") {
            // Toolbar: filter field + copy + refresh. Filter is purely a view
            // concern (substring match, case-insensitive); the on-disk log is
            // unchanged, so unchecking the filter shows everything again.
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filtr (např. ERROR)", text: $logFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                if !logFilter.isEmpty {
                    Button {
                        logFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Zrušit filtr")
                }
                Spacer()
                Button {
                    copyLogToPasteboard()
                } label: {
                    Label("Kopírovat", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .tint(.blue)
                .controlSize(.small)
                .disabled(filteredLogText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Zkopírovat zobrazené řádky do schránky")
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
                    Text(displayedLogText)
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
                .onChange(of: logFilter) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Substring-filtered view of `vm.logText`. Empty filter → original text;
    /// non-empty filter → only lines that contain the term (case-insensitive).
    /// The header "—" placeholder is returned when the filter excludes
    /// everything so the ScrollView keeps a non-zero height.
    private var filteredLogText: String {
        let term = logFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return vm.logText }
        let lower = term.lowercased()
        let kept = vm.logText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.lowercased().contains(lower) }
        if kept.isEmpty { return "" }
        return kept.joined(separator: "\n")
    }

    /// Same as `filteredLogText` but substitutes a single space for the empty
    /// state so the ScrollView preserves height (matches the original
    /// `logText.isEmpty ? " " : logText` placeholder convention).
    private var displayedLogText: String {
        let text = filteredLogText
        return text.isEmpty ? " " : text
    }

    /// Copies the currently displayed log text to the system pasteboard. With an
    /// active filter, only the visible (matching) lines are copied — that
    /// matches what the user sees, which is what they almost certainly want.
    private func copyLogToPasteboard() {
        let text = filteredLogText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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
