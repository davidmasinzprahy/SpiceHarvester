import Foundation

struct BatchCheckpoint: Codable {
    let completedRelativePaths: [String]
    let totalFileCount: Int
    let prompt: String
    let modelName: String
    let timestamp: Date
}

actor CheckpointWriter {
    static let fileName = ".spice-checkpoint.json"

    static func checkpointURL(outputDirectory: URL) -> URL {
        outputDirectory.appendingPathComponent(fileName)
    }

    static func save(_ checkpoint: BatchCheckpoint, outputDirectory: URL) async {
        let url = checkpointURL(outputDirectory: outputDirectory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(checkpoint) else { return }
        try? data.write(to: url)
    }

    static func load(outputDirectory: URL) async -> BatchCheckpoint? {
        let url = checkpointURL(outputDirectory: outputDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BatchCheckpoint.self, from: data)
    }

    static func delete(outputDirectory: URL) async {
        let url = checkpointURL(outputDirectory: outputDirectory)
        try? FileManager.default.removeItem(at: url)
    }
}

struct BatchOrchestrator {
    struct Config {
        let inputRootURL: URL
        let outputRootURL: URL
        let relevantFiles: [URL]
        let prompt: String
        let continuationPrompt: String?
        let modelName: String
        let secondaryModelName: String?
        let pipelineProfile: PipelineProfile
        let preprocessingProfile: PreprocessingProfile
        let contextLimit: Int?
        let parallelRequests: Int
        let useChunking: Bool
        let summarizeChunks: Bool
        let conciseOutput: Bool
        let controller: AnalysisRunController
        let extractionService: any ExtractionServicing
        let analysisService: any AnalysisServicing
        let embeddingService: (any EmbeddingServicing)?
        let embeddingModelName: String
        var skipRelativePaths: Set<String> = []
        var isPaused: @Sendable () -> Bool = { false }
    }

    struct Hooks {
        let onProgressInit: @Sendable (_ total: Int) -> Void
        let onStatus: @Sendable (_ text: String) -> Void
        let onChunkProgress: @Sendable (_ current: Int, _ total: Int) -> Void
        let onFileProgress: @Sendable (_ current: Int, _ total: Int) -> Void
        let onRequestKind: @Sendable (_ kind: String) -> Void
        let onChunkReset: @Sendable () -> Void
        var onWorkerStatuses: @Sendable (_ statuses: [String]) -> Void = { _ in }
    }

    private actor WorkerTracker {
        private var statuses: [Int: String] = [:]

        func update(workerID: Int, status: String) {
            statuses[workerID] = status
        }

        func remove(workerID: Int) {
            statuses.removeValue(forKey: workerID)
        }

        func allStatuses() -> [String] {
            statuses.sorted(by: { $0.key < $1.key }).map(\.value)
        }
    }

    /// Wait while paused, checking every 0.5s. Returns true if cancelled during pause.
    private static func waitWhilePaused(config: Config, hooks: Hooks) async -> Bool {
        var emittedPauseStatus = false
        while config.isPaused() {
            if Task.isCancelled { return true }
            if !emittedPauseStatus {
                hooks.onStatus("Pozastaveno...")
                emittedPauseStatus = true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return Task.isCancelled
    }

    struct Result {
        let relevantFileCount: Int
        let wasCancelled: Bool
    }

    private actor HookGate {
        private var lastStatusText = ""
        private var lastStatusAt = Date.distantPast
        private var lastChunk: (current: Int, total: Int) = (0, 0)
        private var lastChunkAt = Date.distantPast
        private var lastRequestKind = ""

        func emitStatus(_ text: String, hook: @Sendable (String) -> Void) {
            let now = Date()
            let isBlockStatus = text.contains("· část ")
            let isSummaryStatus = text.contains("finální souhrn")

            if text == lastStatusText, now.timeIntervalSince(lastStatusAt) < 0.2 {
                return
            }

            if isBlockStatus && !isSummaryStatus && now.timeIntervalSince(lastStatusAt) < 0.12 {
                return
            }

            lastStatusText = text
            lastStatusAt = now
            hook(text)
        }

        func emitChunkProgress(current: Int, total: Int, hook: @Sendable (Int, Int) -> Void) {
            let now = Date()
            let previous = lastChunk

            if (current, total) == previous {
                return
            }

            let mustEmit = current <= 1
                || current == total
                || current >= previous.current + 5
                || now.timeIntervalSince(lastChunkAt) >= 0.12

            guard mustEmit else { return }

            lastChunk = (current, total)
            lastChunkAt = now
            hook(current, total)
        }

        func emitRequestKind(_ kind: String, hook: @Sendable (String) -> Void) {
            guard kind != lastRequestKind else { return }
            lastRequestKind = kind
            hook(kind)
        }

        func resetChunk(hook: @Sendable () -> Void) {
            lastChunk = (0, 0)
            lastChunkAt = Date.distantPast
            hook()
        }
    }

    static func run(config: Config, hooks: Hooks) async -> Result {
        let fileManager = FileManager.default
        let relevantFiles = config.relevantFiles.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        hooks.onProgressInit(relevantFiles.count)

        if config.preprocessingProfile.useOpenDataLoader && !config.preprocessingProfile.useVision {
            let pdfPaths = relevantFiles
                .filter { $0.pathExtension.lowercased() == "pdf" }
                .map(\.path)
            if !pdfPaths.isEmpty {
                hooks.onStatus("Předzpracovávám \(pdfPaths.count) PDF přes OpenDataLoader (batch)...")
                config.extractionService.prefetchPDFText(paths: pdfPaths)
                hooks.onStatus("OpenDataLoader batch předzpracování dokončeno.")
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let logFileURL = config.outputRootURL.appendingPathComponent("log--\(timestamp).csv")
        try? "soubor;stav;počet_kroků_nebo_bloků;velikost_inputu_znaků;jazyk;extrakce_s;inference_s;zápis_s;chyba;čas_celkem_s;model\n".write(to: logFileURL, atomically: true, encoding: .utf8)
        let logHandle = try? FileHandle(forWritingTo: logFileURL)
        defer { try? logHandle?.close() }

        func appendLog(_ entry: String) {
            if let data = entry.data(using: .utf8) {
                logHandle?.seekToEndOfFile()
                logHandle?.write(data)
            }
        }

        let chunkingPromptTemplate = "\(config.prompt)\n\nOdpověď napiš výstižně a stručně jako souvislý text. Nepoužívej tabulky, odrážky ani technické poznámky."
        let chunkSize: Int = {
            guard let contextLimit = config.contextLimit else { return config.pipelineProfile.chunkSize }
            let reservedOutput = max(512, Int(Double(contextLimit) * 0.22))
            let promptTokens = max(1, Int(ceil(Double(chunkingPromptTemplate.count) / 4.0)))
            let available = contextLimit - reservedOutput - promptTokens - 96
            let safeInputCharacters = max(256, available) * 4
            return max(500, min(config.pipelineProfile.chunkSize, safeInputCharacters))
        }()

        actor FileCursor {
            private let files: [URL]
            private var index = 0

            init(files: [URL]) {
                self.files = files
            }

            func next() -> URL? {
                guard index < files.count else { return nil }
                let value = files[index]
                index += 1
                return value
            }
        }

        actor RunAccumulator {
            private var processedCount = 0
            private var allResponses: [String] = []
            private var completedRelativePaths: [String] = []
            private var failedFiles: [(url: URL, relativePath: String)] = []
            private let logHandle: FileHandle?

            init(logHandle: FileHandle?, initialCompletedPaths: [String] = []) {
                self.logHandle = logHandle
                self.completedRelativePaths = initialCompletedPaths
            }

            func appendSkip(logEntry: String, relativePath: String) -> Int {
                processedCount += 1
                completedRelativePaths.append(relativePath)
                if let data = logEntry.data(using: .utf8) {
                    logHandle?.seekToEndOfFile()
                    logHandle?.write(data)
                }
                return processedCount
            }

            func appendResult(logEntry: String, responseBlock: String, relativePath: String) -> Int {
                processedCount += 1
                allResponses.append(responseBlock)
                completedRelativePaths.append(relativePath)
                if let data = logEntry.data(using: .utf8) {
                    logHandle?.seekToEndOfFile()
                    logHandle?.write(data)
                }
                return processedCount
            }

            func appendFailed(url: URL, relativePath: String) {
                failedFiles.append((url: url, relativePath: relativePath))
            }

            func currentFailedFiles() -> [(url: URL, relativePath: String)] {
                failedFiles
            }

            func updateResponse(forRelativePath relativePath: String, newResponseBlock: String) {
                if let idx = allResponses.firstIndex(where: { $0.hasPrefix("Soubor: \(relativePath)") }) {
                    allResponses[idx] = newResponseBlock
                } else {
                    allResponses.append(newResponseBlock)
                }
            }

            func removeFailed(relativePath: String) {
                failedFiles.removeAll { $0.relativePath == relativePath }
            }

            func mergedResponses() -> [String] {
                allResponses
            }

            func currentCompletedPaths() -> [String] {
                completedRelativePaths
            }
        }

        let cursor = FileCursor(files: relevantFiles)
        let accumulator = RunAccumulator(
            logHandle: logHandle,
            initialCompletedPaths: Array(config.skipRelativePaths)
        )
        let hookGate = HookGate()

        // Embedding deduplication cache (per-run, in-memory, shared across workers)
        let dedupCache: DeduplicationCache? = {
            guard config.preprocessingProfile.useEmbeddingDedup,
                  config.embeddingService != nil else { return nil }
            return DeduplicationCache(threshold: config.preprocessingProfile.embeddingSimilarityThreshold)
        }()

        // If resuming, account for already-skipped files in progress
        let skipCount = config.skipRelativePaths.count
        if skipCount > 0 {
            hooks.onFileProgress(skipCount, relevantFiles.count)
        }

        let workerTracker = WorkerTracker()

        await withTaskGroup(of: Void.self) { group in
            let workerCount = max(1, min(config.parallelRequests, relevantFiles.count))

            for workerIndex in 0..<workerCount {
                group.addTask {
                    while let fileURL = await cursor.next() {
                        if Task.isCancelled { break }
                        if await waitWhilePaused(config: config, hooks: hooks) { break }

                        let startTime = Date()
                        let rel = relativePath(for: fileURL, inputRootURL: config.inputRootURL)

                        // Phase F: Skip already-processed files
                        if config.skipRelativePaths.contains(rel) {
                            continue
                        }

                        let ext = fileURL.pathExtension.lowercased()
                        appendLog("\(rel);START;0;0;;;;;;;model: \(config.modelName)\n")
                        await workerTracker.update(workerID: workerIndex, status: "čte soubor \(rel)")
                        hooks.onWorkerStatuses(await workerTracker.allStatuses())
                        await hookGate.emitStatus("Čtu soubor \(rel) (\(ext))...", hook: hooks.onStatus)

                        let useVisionPath = config.preprocessingProfile.useVision && ext == "pdf"
                        if config.preprocessingProfile.useVision && ext != "pdf" {
                            await hookGate.emitStatus(
                                "Vision mode není dostupný pro .\(ext) — použiji textovou extrakci · \(rel)",
                                hook: hooks.onStatus
                            )
                        }
                        let extractionStart = Date()

                        // Vision path skips text extraction entirely
                        let inputText: String
                        let detectedLanguage: String
                        let inputKB: String
                        let forceConcise: Bool
                        let extractionDuration: TimeInterval

                        if useVisionPath {
                            inputText = ""
                            detectedLanguage = "—"
                            inputKB = "—"
                            forceConcise = false
                            extractionDuration = Date().timeIntervalSince(extractionStart)
                            appendLog("\(rel);VISION_START;0;0;—;\(String(format: "%.2f", extractionDuration));;;;;vision mode\n")
                            await hookGate.emitStatus("Vision mode: \(rel) — přeskakuji textovou extrakci", hook: hooks.onStatus)
                        } else {
                            let rawText = config.extractionService.extractText(from: fileURL.path, ocrResolutionWidth: config.preprocessingProfile.ocrResolutionWidth)
                            let rawCount = rawText.count
                            inputText = PreprocessingProfile.preprocess(rawText, profile: config.preprocessingProfile)
                            forceConcise = inputText.count < 3000
                            extractionDuration = Date().timeIntervalSince(extractionStart)
                            detectedLanguage = config.extractionService.detectLanguage(for: inputText)
                            inputKB = String(format: "%.0f", Double(inputText.count) / 1024.0)
                            let savedChars = rawCount - inputText.count
                            let savedPct = rawCount > 0 ? Int(round(Double(savedChars) / Double(rawCount) * 100)) : 0

                            appendLog("\(rel);EXTRACTED;0;\(inputText.count);\(detectedLanguage);\(String(format: "%.2f", extractionDuration));;;;;extrakce OK · preprocessing: \(rawCount)→\(inputText.count) (−\(savedPct)%)\n")
                            let savingsNote = savedChars > 0 ? " · preprocessing −\(savedPct)% (\(savedChars) znaků)" : ""
                            await hookGate.emitStatus(
                                "Soubor načten: \(rel) · \(inputKB) KB textu · jazyk: \(detectedLanguage) · \(String(format: "%.1f", extractionDuration))s\(savingsNote)",
                                hook: hooks.onStatus
                            )

                            if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                let totalDuration = Date().timeIntervalSince(startTime)
                                let logEntry = "\(rel);SKIP;0;0;\(detectedLanguage);\(String(format: "%.2f", extractionDuration));0.00;0.00;Prázdný vstup;\(String(format: "%.2f", totalDuration));\(config.modelName) | \(config.pipelineProfile.id)\n"
                                let currentProcessed = await accumulator.appendSkip(logEntry: logEntry, relativePath: rel)
                                hooks.onFileProgress(currentProcessed + skipCount, relevantFiles.count)

                                let paths = await accumulator.currentCompletedPaths()
                                await CheckpointWriter.save(
                                    BatchCheckpoint(
                                        completedRelativePaths: paths,
                                        totalFileCount: relevantFiles.count,
                                        prompt: config.prompt,
                                        modelName: config.modelName,
                                        timestamp: Date()
                                    ),
                                    outputDirectory: config.outputRootURL
                                )
                                continue
                            }
                        }

                        // MARK: Vision vs Text path
                        var chunkSummaries: [String] = []
                        var inferenceDuration: TimeInterval = 0
                        var hadError = false
                        var errorDescription = ""
                        let chunkCount: Int

                        if useVisionPath {
                            // --- Vision path: send page images in batches ---
                            let pageImages = config.extractionService.extractPageImages(
                                from: fileURL.path,
                                resolutionWidth: config.preprocessingProfile.visionResolutionWidth
                            )

                            if pageImages.isEmpty {
                                chunkCount = 1
                                hadError = true
                                errorDescription = "Vision: PDF neobsahuje žádné stránky nebo se nepodařilo renderovat obrázky (\(fileURL.lastPathComponent))"
                                chunkSummaries.append("[Chyba: \(errorDescription)]")
                            } else {
                                let batchSize = max(1, config.preprocessingProfile.visionPageBatchSize)
                                let batches = stride(from: 0, to: pageImages.count, by: batchSize).map {
                                    Array(pageImages[$0..<min($0 + batchSize, pageImages.count)])
                                }
                                chunkCount = batches.count
                                let totalImageKB = pageImages.reduce(0) { $0 + $1.count } / 1024

                                await hookGate.emitStatus(
                                    "Vision mode: \(pageImages.count) stránek · \(batches.count) dávek po \(batchSize) · \(totalImageKB) KB · \(rel)",
                                    hook: hooks.onStatus
                                )

                                for (batchIndex, batch) in batches.enumerated() {
                                    if Task.isCancelled { break }
                                    if await waitWhilePaused(config: config, hooks: hooks) { break }

                                    let batchKB = batch.reduce(0) { $0 + $1.count } / 1024
                                    await hookGate.emitChunkProgress(current: batchIndex + 1, total: batches.count, hook: hooks.onChunkProgress)
                                    await hookGate.emitRequestKind("odesílám obrázky (vision)", hook: hooks.onRequestKind)
                                    await workerTracker.update(workerID: workerIndex, status: "\(rel) · vision dávka \(batchIndex + 1)/\(batches.count)")
                                    hooks.onWorkerStatuses(await workerTracker.allStatuses())
                                    await hookGate.emitStatus(
                                        "Odesílám dávku \(batchIndex + 1)/\(batches.count) (\(batch.count) stránek, \(batchKB) KB) souboru \(rel)...",
                                        hook: hooks.onStatus
                                    )

                                    do {
                                        let visionPrompt = config.conciseOutput
                                            ? "\(config.prompt)\n\nOdpověď napiš výstižně a stručně jako souvislý text. Nepoužívej tabulky, odrážky ani technické poznámky."
                                            : config.prompt
                                        let visionResult = try await config.analysisService.analyzeWithVision(
                                            images: batch,
                                            promptText: visionPrompt,
                                            modelName: config.modelName
                                        )
                                        chunkSummaries.append(visionResult.response)
                                        inferenceDuration += visionResult.duration
                                        appendLog("\(rel);VISION;\(batchIndex + 1)/\(batches.count);\(batchKB)KB;;;;\(String(format: "%.2f", visionResult.duration));;vision OK\n")
                                    } catch let error as AnalysisError {
                                        hadError = true
                                        errorDescription = error.localizedDescription
                                        chunkSummaries.append("[Chyba vision: \(error.localizedDescription)]")
                                        appendLog("\(rel);VISION_ERR;\(batchIndex + 1)/\(batches.count);\(batchKB)KB;;;;;\(error.localizedDescription);\n")
                                        if case .cancelled = error { break }
                                    } catch {
                                        hadError = true
                                        errorDescription = error.localizedDescription
                                        chunkSummaries.append("[Chyba: \(error.localizedDescription)]")
                                    }
                                }
                            }
                        } else {
                            // --- Text path (original) ---
                            let structuredChunks: [String]? =
                                (config.preprocessingProfile.useOpenDataLoader && ext == "pdf" && config.useChunking)
                                ? config.extractionService.extractStructuredChunks(from: fileURL.path, maxChunkCharacters: chunkSize)
                                : nil

                            let inputChunks: [String] = config.useChunking
                                ? (structuredChunks ?? (config.preprocessingProfile.smartChunking
                                    ? PreprocessingProfile.chunkSmart(
                                        inputText,
                                        chunkSize: chunkSize,
                                        chunkOverlap: config.pipelineProfile.chunkOverlap
                                    )
                                    : PipelineProfile.chunkText(
                                        inputText,
                                        chunkSize: chunkSize,
                                        chunkOverlap: config.pipelineProfile.chunkOverlap
                                    )))
                                : [inputText]

                            chunkCount = inputChunks.count

                            if chunkCount > 1 {
                                let chunkKB = String(format: "%.0f", Double(chunkSize) / 1024.0)
                                let chunkingSource = (structuredChunks != nil) ? "strukturované bloky" : "text"
                                await hookGate.emitStatus(
                                    "Soubor \(rel) rozdělen na \(chunkCount) částí (část ~\(chunkKB) KB, zdroj: \(chunkingSource)) · postupně odesílám na model...",
                                    hook: hooks.onStatus
                                )
                            } else {
                                await hookGate.emitStatus(
                                    "Odesílám celý soubor \(rel) na model (\(inputKB) KB)...",
                                    hook: hooks.onStatus
                                )
                            }

                            await hookGate.emitChunkProgress(
                                current: chunkCount > 0 ? 1 : 0,
                                total: chunkCount,
                                hook: hooks.onChunkProgress
                            )

                            for (index, chunk) in inputChunks.enumerated() {
                                if Task.isCancelled { break }
                                if await waitWhilePaused(config: config, hooks: hooks) { break }
                                await hookGate.emitChunkProgress(
                                    current: index + 1,
                                    total: chunkCount,
                                    hook: hooks.onChunkProgress
                                )
                                let chunkCharCount = chunk.count
                                let chunkKBStr = String(format: "%.0f", Double(chunkCharCount) / 1024.0)
                                await hookGate.emitRequestKind("odesílám část souboru", hook: hooks.onRequestKind)
                                let workerStatus = "\(rel) · část \(index + 1)/\(chunkCount)"
                                await workerTracker.update(workerID: workerIndex, status: workerStatus)
                                hooks.onWorkerStatuses(await workerTracker.allStatuses())
                                await hookGate.emitStatus(
                                    "Odesílám část \(index + 1) z \(chunkCount) (\(chunkKBStr) KB) souboru \(rel) na model...",
                                    hook: hooks.onStatus
                                )

                                let basePrompt: String
                                if index > 0, chunkCount > 1, let continuation = config.continuationPrompt {
                                    basePrompt = continuation
                                } else {
                                    basePrompt = config.prompt
                                }
                                let effectivePrompt = (config.conciseOutput || forceConcise)
                                    ? "\(basePrompt)\n\nOdpověď napiš výstižně a stručně jako souvislý text. Nepoužívej tabulky, odrážky ani technické poznámky."
                                    : basePrompt

                                // Embedding dedup check (optional)
                                var chunkEmbedding: [Float]? = nil
                                var cachedResponse: String? = nil
                                if let cache = dedupCache, let embedService = config.embeddingService {
                                    do {
                                        let vectors = try await embedService.embed(texts: [chunk], modelName: config.embeddingModelName)
                                        if let first = vectors.first {
                                            chunkEmbedding = first
                                            if let hit = await cache.findSimilar(first) {
                                                cachedResponse = hit
                                                await hookGate.emitStatus("Dedup hit: \(rel) · blok \(index + 1)/\(chunkCount) — reuse", hook: hooks.onStatus)
                                                appendLog("\(rel);DEDUP_HIT;\(index + 1)/\(chunkCount);\(chunk.count);;;;0.00;;cached\n")
                                            }
                                        }
                                    } catch {
                                        appendLog("\(rel);EMBED_ERR;\(index + 1)/\(chunkCount);\(chunk.count);;;;;\(error.localizedDescription);\n")
                                    }
                                }

                                if let cached = cachedResponse {
                                    chunkSummaries.append(cached)
                                    continue
                                }

                                do {
                                    let chunkResult = try await config.analysisService.analyzeChunkWithRetry(
                                        chunk: chunk,
                                        promptText: effectivePrompt,
                                        modelName: config.modelName,
                                        minimumChunkSize: 500
                                    )
                                    chunkSummaries.append(contentsOf: chunkResult.responses)
                                    inferenceDuration += chunkResult.duration
                                    appendLog("\(rel);CHUNK;\(index + 1)/\(chunkCount);\(chunk.count);;;;\(String(format: "%.2f", chunkResult.duration));;blok OK\n")

                                    // Store in dedup cache for future chunks —
                                    // only cache clean single-response results.
                                    // Skip caching if: error marker, empty response, or multi-part response from nested retry
                                    if let cache = dedupCache,
                                       let embedding = chunkEmbedding,
                                       chunkResult.responses.count == 1,
                                       let firstResponse = chunkResult.responses.first {
                                        let trimmed = firstResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                                        let isError = trimmed.hasPrefix("[Chyba") || trimmed.hasPrefix("[Žádná")
                                        if !trimmed.isEmpty && !isError {
                                            await cache.store(
                                                embedding: embedding,
                                                response: firstResponse,
                                                preview: String(chunk.prefix(80))
                                            )
                                        }
                                    }
                            } catch let error as AnalysisError {
                                hadError = true
                                errorDescription = error.localizedDescription
                                chunkSummaries.append("[Chyba: \(error.localizedDescription)]")
                                appendLog("\(rel);CHUNK_ERR;\(index + 1)/\(chunkCount);\(chunk.count);;;;;\(error.localizedDescription);\n")
                                if case .cancelled = error { break }
                            } catch {
                                hadError = true
                                errorDescription = error.localizedDescription
                                chunkSummaries.append("[Chyba: \(error.localizedDescription)]")
                            }
                        }
                        } // end text path else

                        var finalSummary = chunkSummaries.joined(separator: "\n\n")

                        if let reducedBinaryAnswer = collapseBinaryResponsesIfNeeded(
                            responses: chunkSummaries,
                            prompt: config.prompt
                        ) {
                            finalSummary = reducedBinaryAnswer
                        } else if !Task.isCancelled && !hadError && chunkCount > 1 {
                            await hookGate.emitRequestKind("skládám výsledek souboru", hook: hooks.onRequestKind)
                            await workerTracker.update(workerID: workerIndex, status: "\(rel) · skládám výsledek")
                            hooks.onWorkerStatuses(await workerTracker.allStatuses())
                            await hookGate.emitStatus(
                                "Všech \(chunkCount) částí zpracováno · skládám dílčí odpovědi do jednoho výsledku · \(rel)",
                                hook: hooks.onStatus
                            )

                            let summarizingTemplate = """
                            Na základě následujících dílčích odpovědí vytvoř jeden finální výsledek pro jeden soubor.

                            Původní zadání uživatele:
                            \(config.prompt)

                            Požadavky:
                            - vrať pouze finální odpověď, ne mezikroky a ne informace po blocích
                            - nepiš technické poznámky o zpracování
                            - pokud zadání vyžaduje ANO/NE, vrať pouze ANO nebo NE
                            - zachovej pouze informace, které vyplývají z podkladů

                            Dílčí odpovědi:
                            """

                            let joinedChunkSummaries = chunkSummaries.joined(separator: "\n\n")
                            let summaryCharacterLimit = config.contextLimit.map { limit in
                                let reservedOutput = max(512, Int(Double(limit) * 0.22))
                                let promptTokens = max(1, Int(ceil(Double(summarizingTemplate.count) / 4.0)))
                                let available = limit - reservedOutput - promptTokens - 96
                                return max(256, available) * 4
                            } ?? 6000

                            do {
                                let summaryModelName = config.secondaryModelName ?? config.modelName
                                let summaryResult = try await config.analysisService.summarizeWithRetry(
                                    summaries: chunkSummaries,
                                    template: summarizingTemplate,
                                    modelName: summaryModelName,
                                    initialCharacterLimit: min(summaryCharacterLimit, joinedChunkSummaries.count)
                                )
                                finalSummary = summaryResult.summary
                                inferenceDuration += summaryResult.duration
                            } catch let error as AnalysisError {
                                hadError = true
                                errorDescription = error.localizedDescription
                                finalSummary += "\n\n[Chyba konsolidace: \(error.localizedDescription)]"
                            } catch {
                                hadError = true
                                errorDescription = error.localizedDescription
                                finalSummary += "\n\n[Chyba konsolidace: \(error.localizedDescription)]"
                            }
                        } else {
                            finalSummary = finalSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        let totalFileDuration = Int(Date().timeIntervalSince(startTime))
                        await hookGate.emitStatus(
                            "Ukládám výsledek souboru \(rel) na disk (\(totalFileDuration)s celkem)...",
                            hook: hooks.onStatus
                        )

                        let writingStart = Date()
                        let outputFileURL = AnalysisSupport.outputFileURL(for: fileURL, relativePath: rel, outputDirectory: config.outputRootURL)
                        try? fileManager.createDirectory(at: outputFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        do {
                            try finalSummary.write(to: outputFileURL, atomically: true, encoding: .utf8)
                            let attrs = try fileManager.attributesOfItem(atPath: outputFileURL.path)
                            let fileSize = attrs[.size] as? UInt64 ?? 0
                            if fileSize == 0 {
                                hadError = true
                                errorDescription += errorDescription.isEmpty ? "Výstupní soubor je prázdný (0 B)" : "; Výstupní soubor je prázdný (0 B)"
                            }
                        } catch {
                            hadError = true
                            errorDescription += errorDescription.isEmpty ? "Chyba zápisu: \(error.localizedDescription)" : "; Chyba zápisu: \(error.localizedDescription)"
                        }
                        let writingDuration = Date().timeIntervalSince(writingStart)

                        // Output quality validation
                        let validationWarnings = AnalysisSupport.validateOutput(finalSummary, inputLength: inputText.count)
                        if !validationWarnings.isEmpty {
                            let warningText = validationWarnings.joined(separator: "; ")
                            appendLog("\(rel);VALIDATION_WARN;;;;;;;;;;\(warningText)\n")
                            await hookGate.emitStatus("Varování kvality výstupu \(rel): \(warningText)", hook: hooks.onStatus)
                        }

                        let status = hadError ? "ERR" : "OK"
                        let inputLength = inputText.count
                        let totalDuration = Date().timeIntervalSince(startTime)
                        let logEntry = "\(rel);\(status);\(chunkCount);\(inputLength);\(detectedLanguage);\(String(format: "%.2f", extractionDuration));\(String(format: "%.2f", inferenceDuration));\(String(format: "%.2f", writingDuration));\(hadError ? errorDescription : "");\(String(format: "%.2f", totalDuration));\(config.modelName) | \(config.pipelineProfile.id)\n"

                        let currentProcessed = await accumulator.appendResult(
                            logEntry: logEntry,
                            responseBlock: "Soubor: \(rel)\n\n\(finalSummary)",
                            relativePath: rel
                        )

                        if hadError {
                            await accumulator.appendFailed(url: fileURL, relativePath: rel)
                        }

                        hooks.onFileProgress(currentProcessed + skipCount, relevantFiles.count)
                        await hookGate.resetChunk(hook: hooks.onChunkReset)

                        let doneCount = currentProcessed + skipCount
                        let totalFiles = relevantFiles.count
                        let statusIcon = hadError ? "⚠️" : "✓"
                        await workerTracker.update(workerID: workerIndex, status: "\(rel) · dokončen")
                        hooks.onWorkerStatuses(await workerTracker.allStatuses())
                        await hookGate.emitStatus(
                            "\(statusIcon) Soubor \(rel) dokončen (\(Int(totalDuration))s) · hotovo \(doneCount) z \(totalFiles)",
                            hook: hooks.onStatus
                        )
                        await hookGate.emitRequestKind("přechod na další soubor", hook: hooks.onRequestKind)

                        // Phase F: Save checkpoint after each file
                        let paths = await accumulator.currentCompletedPaths()
                        await CheckpointWriter.save(
                            BatchCheckpoint(
                                completedRelativePaths: paths,
                                totalFileCount: relevantFiles.count,
                                prompt: config.prompt,
                                modelName: config.modelName,
                                timestamp: Date()
                            ),
                            outputDirectory: config.outputRootURL
                        )
                    }
                }
            }

            await group.waitForAll()
        }

        // Emit dedup stats
        if let cache = dedupCache {
            let stats = await cache.stats()
            if stats.hits > 0 || stats.misses > 0 {
                let total = stats.hits + stats.misses
                let pct = total > 0 ? Int(round(Double(stats.hits) / Double(total) * 100)) : 0
                await hookGate.emitStatus("Dedup: \(stats.hits)/\(total) hits (−\(pct)% LLM volání), uloženo \(stats.stored) unikátních bloků", hook: hooks.onStatus)
                let summaryLog = ";DEDUP_SUMMARY;\(stats.hits);\(stats.misses);\(stats.stored);;;;;;;−\(pct)% LLM calls\n"
                if let data = summaryLog.data(using: .utf8) {
                    logHandle?.seekToEndOfFile()
                    logHandle?.write(data)
                }
            }
        }

        // Retry pass for failed files
        let failedFilesSnapshot = await accumulator.currentFailedFiles()
        if !failedFilesSnapshot.isEmpty && !Task.isCancelled {
            let failedCount = failedFilesSnapshot.count
            for (index, failed) in failedFilesSnapshot.enumerated() {
                if Task.isCancelled { break }

                await hookGate.emitStatus(
                    "Opakuji neúspěšný soubor \(index + 1) z \(failedCount)...",
                    hook: hooks.onStatus
                )

                let retryExt = failed.url.pathExtension.lowercased()
                let retryUseVision = config.preprocessingProfile.useVision && retryExt == "pdf"

                var retryResponse: String = ""
                var retryDuration: TimeInterval = 0
                var retryInputCount: Int = 0

                do {
                    if retryUseVision {
                        // Vision retry path — with batching (same as primary pipeline)
                        let pageImages = config.extractionService.extractPageImages(
                            from: failed.url.path,
                            resolutionWidth: config.preprocessingProfile.visionResolutionWidth
                        )
                        guard !pageImages.isEmpty else { continue }
                        retryInputCount = pageImages.reduce(0) { $0 + $1.count }

                        let batchSize = max(1, config.preprocessingProfile.visionPageBatchSize)
                        let batches = stride(from: 0, to: pageImages.count, by: batchSize).map {
                            Array(pageImages[$0..<min($0 + batchSize, pageImages.count)])
                        }

                        var batchResponses: [String] = []
                        var batchDuration: TimeInterval = 0
                        var cancelledDuringVisionRetry = false
                        for batch in batches {
                            if Task.isCancelled {
                                cancelledDuringVisionRetry = true
                                break
                            }
                            let visionResult = try await config.analysisService.analyzeWithVision(
                                images: batch,
                                promptText: config.prompt,
                                modelName: config.modelName
                            )
                            batchResponses.append(visionResult.response)
                            batchDuration += visionResult.duration
                        }
                        if cancelledDuringVisionRetry {
                            throw AnalysisError.cancelled
                        }
                        retryResponse = batchResponses.joined(separator: "\n\n")
                        retryDuration = batchDuration
                    } else {
                        // Text retry path
                        let retryRaw = config.extractionService.extractText(from: failed.url.path, ocrResolutionWidth: config.preprocessingProfile.ocrResolutionWidth)
                        let retryText = PreprocessingProfile.preprocess(retryRaw, profile: config.preprocessingProfile)
                        guard !retryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        retryInputCount = retryText.count

                        let retryResult = try await config.analysisService.analyzeChunkWithRetry(
                            chunk: retryText,
                            promptText: config.prompt,
                            modelName: config.modelName,
                            minimumChunkSize: 500
                        )
                        retryResponse = retryResult.responses.joined(separator: "\n\n")
                        retryDuration = retryResult.duration
                    }
                    let outputFileURL = AnalysisSupport.outputFileURL(
                        for: failed.url,
                        relativePath: failed.relativePath,
                        outputDirectory: config.outputRootURL
                    )
                    try? fileManager.createDirectory(at: outputFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try retryResponse.write(to: outputFileURL, atomically: true, encoding: .utf8)
                    await accumulator.updateResponse(
                        forRelativePath: failed.relativePath,
                        newResponseBlock: "Soubor: \(failed.relativePath)\n\n\(retryResponse)"
                    )
                    await accumulator.removeFailed(relativePath: failed.relativePath)

                    let logEntry = "\(failed.relativePath);RETRY_OK;1;\(retryInputCount);;0.00;\(String(format: "%.2f", retryDuration));0.00;;\(String(format: "%.2f", retryDuration));\(config.modelName) | \(config.pipelineProfile.id)\n"
                    if let data = logEntry.data(using: .utf8) {
                        logHandle?.seekToEndOfFile()
                        logHandle?.write(data)
                    }

                    await hookGate.emitStatus("RETRY_OK: \(failed.relativePath)", hook: hooks.onStatus)
                } catch {
                    let logEntry = "\(failed.relativePath);RETRY_ERR;1;\(retryInputCount);;0.00;0.00;0.00;\(error.localizedDescription);0.00;\(config.modelName) | \(config.pipelineProfile.id)\n"
                    if let data = logEntry.data(using: .utf8) {
                        logHandle?.seekToEndOfFile()
                        logHandle?.write(data)
                    }
                    await hookGate.emitStatus("RETRY_ERR: \(failed.relativePath) - \(error.localizedDescription)", hook: hooks.onStatus)
                }
            }
        }

        let allResponses = await accumulator.mergedResponses()

        let mergedFileName = "vystup--\(timestamp)--.txt"
        let mergedFileURL = config.outputRootURL.appendingPathComponent(mergedFileName)
        let mergedSections = allResponses.joined(separator: "\n\n---\n\n")
        let mergedText = """
        Prompt:

        \(config.prompt.trimmingCharacters(in: .whitespacesAndNewlines))

        === Odpovědi podle souborů ===

        \(mergedSections)
        """
        do {
            try mergedText.write(to: mergedFileURL, atomically: true, encoding: .utf8)
        } catch {
            await hookGate.emitStatus("Varování: nepodařilo se zapsat agregovaný výstup: \(error.localizedDescription)", hook: hooks.onStatus)
        }

        // XLSX export agregovaného výstupu
        let xlsxFileName = "vystup--\(timestamp)--.xlsx"
        let xlsxFileURL = config.outputRootURL.appendingPathComponent(xlsxFileName)
        var xlsxRows: [XLSXWriter.Row] = [XLSXWriter.Row(cells: ["Soubor", "Odpověď"])]
        for responseBlock in allResponses {
            let parts = responseBlock.split(separator: "\n", maxSplits: 2).map(String.init)
            let fileName = parts.first?.replacingOccurrences(of: "Soubor: ", with: "") ?? ""
            let answer = parts.count > 1 ? parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : ""
            xlsxRows.append(XLSXWriter.Row(cells: [fileName, answer]))
        }
        do {
            try XLSXWriter.write(rows: xlsxRows, sheetName: "Výsledky", to: xlsxFileURL)
        } catch {
            await hookGate.emitStatus("Varování: nepodařilo se zapsat XLSX výstup: \(error.localizedDescription)", hook: hooks.onStatus)
        }

        if config.summarizeChunks && !Task.isCancelled && !allResponses.isEmpty {
            let globalSummaryTemplate = """
            Na základě následujících výsledků po jednotlivých souborech vytvoř jeden celkový souhrn celé dávky.

            Původní zadání uživatele:
            \(config.prompt)

            Požadavky:
            - napiš jeden souvislý přehled bez technických poznámek
            - neopakuj stejné informace
            - uveď jen to, co vyplývá z podkladů
            - když zadání vyžaduje ANO/NE, zachovej tento styl odpovědi

            Výsledky po souborech:
            """
            let joinedResponses = allResponses.joined(separator: "\n\n")
            let globalSummaryLimit = config.contextLimit.map { limit in
                let reservedOutput = max(512, Int(Double(limit) * 0.22))
                let promptTokens = max(1, Int(ceil(Double(globalSummaryTemplate.count) / 4.0)))
                let available = limit - reservedOutput - promptTokens - 96
                return max(256, available) * 4
            } ?? 7000

            do {
                let globalSummaryModelName = config.secondaryModelName ?? config.modelName
                let globalSummaryResult = try await config.analysisService.summarizeWithRetry(
                    summaries: allResponses,
                    template: globalSummaryTemplate,
                    modelName: globalSummaryModelName,
                    initialCharacterLimit: min(globalSummaryLimit, joinedResponses.count)
                )
                let globalSummaryFileURL = config.outputRootURL.appendingPathComponent("souhrn--\(timestamp)--.txt")
                let globalSummaryText = """
                Prompt:

                \(config.prompt.trimmingCharacters(in: .whitespacesAndNewlines))

                === Celkový souhrn dávky ===

                \(globalSummaryResult.summary)
                """
                do {
                    try globalSummaryText.write(to: globalSummaryFileURL, atomically: true, encoding: .utf8)
                } catch {
                    await hookGate.emitStatus("Varování: nepodařilo se zapsat celkový souhrn: \(error.localizedDescription)", hook: hooks.onStatus)
                }
            } catch {
                // Global summary failed; not fatal
            }
        }

        return Result(
            relevantFileCount: relevantFiles.count,
            wasCancelled: Task.isCancelled
        )
    }

    private static func collapseBinaryResponsesIfNeeded(responses: [String], prompt: String) -> String? {
        guard responses.count > 1 else { return nil }

        let normalizedPrompt = prompt.lowercased()
        let isBinaryPrompt = normalizedPrompt.contains("ano/ne")
            || normalizedPrompt.contains("ano / ne")
            || normalizedPrompt.contains("yes/no")
            || normalizedPrompt.contains("yes / no")
            || normalizedPrompt.contains("pouze ano")
            || normalizedPrompt.contains("stačí ano")

        guard isBinaryPrompt else { return nil }

        enum Binary {
            case yes
            case no
        }

        func parseBinary(_ text: String) -> Binary? {
            let uppercased = text.uppercased()
            let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            let tokens = uppercased
                .components(separatedBy: separators)
                .filter { !$0.isEmpty }

            for token in tokens {
                if ["ANO", "YES", "TRUE"].contains(token) {
                    return .yes
                }
                if ["NE", "NO", "FALSE"].contains(token) {
                    return .no
                }
            }

            return nil
        }

        let decisions = responses.compactMap(parseBinary)
        guard decisions.count == responses.count else { return nil }

        let yesCount = decisions.filter { $0 == .yes }.count
        let noCount = decisions.count - yesCount

        if yesCount > 0 && noCount == 0 { return "ANO" }
        if noCount > 0 && yesCount == 0 { return "NE" }

        if normalizedPrompt.contains("obsahuje") || normalizedPrompt.contains("contains") {
            return yesCount > 0 ? "ANO" : "NE"
        }

        return yesCount >= noCount ? "ANO" : "NE"
    }

    private static func relativePath(for fileURL: URL, inputRootURL: URL) -> String {
        let standardizedFilePath = fileURL.standardizedFileURL.path
        let standardizedRoot = inputRootURL.standardizedFileURL.path

        if standardizedFilePath == standardizedRoot {
            return fileURL.lastPathComponent
        }

        let rootPrefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        if standardizedFilePath.hasPrefix(rootPrefix) {
            return String(standardizedFilePath.dropFirst(rootPrefix.count))
        }

        return fileURL.lastPathComponent
    }

}
