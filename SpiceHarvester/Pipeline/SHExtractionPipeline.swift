import Foundation

actor SHEmbeddingRunCache {
    private var values: [String: [Double]] = [:]

    func load(key: String) -> [Double]? {
        values[key]
    }

    func save(_ value: [Double], key: String) {
        values[key] = value
    }
}

enum SHExtractionProgressKind: Sendable {
    case documents
    case lmSteps
}

final class SHExtractionPipeline {
    // MARK: – Constants

    /// System prompt — intentionally minimal. We DO NOT inject any schema of our own;
    /// the user's prompt is the sole source of truth for the output shape.
    private static let extractionSystemPrompt =
        "Jsi extrakční engine. Odpovídej výhradně validním JSON podle schématu ze zadání. Nevracej markdown ani vysvětlení, pouze samotný JSON."

    /// Chunking parameters for the SEARCH (RAG) mode.
    private static let searchChunkSize = 1500
    private static let searchChunkOverlap = 250
    private static let searchTopChunks = 6
    private static let searchRerankCandidates = 20
    /// Fallback chars-per-token ratio for Czech medical text when the server-side
    /// tokenizer isn't available (non-LM-Studio backends, older versions). English
    /// averages ~4, Czech with diacritics and longer words averages closer to ~3.
    /// Conservative to avoid under-counting.
    private static let czechCharsPerToken: Double = 3.0
    /// Fraction of the model context reserved for the user input. The remaining
    /// 30 % covers response generation, system prompt, chat-template overhead,
    /// and a safety margin. Lowered from 0.85 → 0.70 after a real-world CONSOLIDATE
    /// batch passed preflight with room to spare but still hung in llama.cpp at
    /// ~60–70 % utilisation (KV cache edge cases). Tighter budget means earlier
    /// map-reduce activation, which is more reliable than a single huge request.
    private static let consolidateInputBudget: Double = 0.70

    // MARK: – State

    private let lmClient: SHOpenAICompatibleClient
    private let logger: SHProcessingLogger
    private let benchmark: SHBenchmarkService
    private let inferenceQueue: SHQueueManager
    private let throttleDelayMs: Int
    private let modelContextTokens: Int
    private let inferenceCache: SHInferenceCache?
    private let embeddingCache: SHEmbeddingCache?
    private let bypassInferenceCache: Bool
    private let schemaValidator = SHResultSchemaValidator()
    private let embeddingRunCache = SHEmbeddingRunCache()

    /// Running cache-hit counter for this pipeline instance. Mutated from multiple
    /// TaskGroup children (one per document in FAST/SEARCH), so guarded by a lock.
    /// Read via `cacheHits()` after the run to surface "X/N cached" in the status bar.
    private var cacheHitCount: Int = 0
    private let cacheHitLock = NSLock()

    init(
        lmClient: SHOpenAICompatibleClient,
        logger: SHProcessingLogger,
        benchmark: SHBenchmarkService,
        maxConcurrentInference: Int,
        throttleDelayMs: Int,
        modelContextTokens: Int = 32_768,
        inferenceCache: SHInferenceCache? = nil,
        embeddingCache: SHEmbeddingCache? = nil,
        bypassInferenceCache: Bool = false
    ) {
        self.lmClient = lmClient
        self.logger = logger
        self.benchmark = benchmark
        self.inferenceQueue = SHQueueManager(maxConcurrent: maxConcurrentInference)
        self.throttleDelayMs = max(0, throttleDelayMs)
        self.modelContextTokens = max(1_024, modelContextTokens)
        self.inferenceCache = inferenceCache
        self.embeddingCache = embeddingCache
        self.bypassInferenceCache = bypassInferenceCache
    }

    func cacheHits() -> Int {
        cacheHitLock.lock()
        defer { cacheHitLock.unlock() }
        return cacheHitCount
    }

    private func incrementCacheHits() {
        cacheHitLock.lock()
        defer { cacheHitLock.unlock() }
        cacheHitCount += 1
    }

    // MARK: – Entry

    func run(
        documents: [SHCachedDocument],
        prompts: [SHPromptTemplate],
        mode: SHExtractionMode,
        server: SHServerConfig,
        inferenceModel: String,
        embeddingModel: String,
        rerankerModel: String,
        onProgress: @escaping @Sendable (_ completed: Int, _ total: Int, _ kind: SHExtractionProgressKind) async -> Void
    ) async -> [SHExtractionResult] {
        if mode == .consolidate {
            return await runConsolidated(
                documents: documents,
                prompts: prompts,
                server: server,
                inferenceModel: inferenceModel,
                onProgress: onProgress
            )
        }

        let total = documents.count
        var completed = 0
        let results = await withTaskGroup(of: SHExtractionResult.self, returning: [SHExtractionResult].self) { group in
            for document in documents {
                group.addTask {
                    do {
                        let result = try await self.inferenceQueue.run {
                            try await self.extractOne(
                                document: document,
                                prompts: prompts,
                                mode: mode,
                                server: server,
                                inferenceModel: inferenceModel,
                                embeddingModel: embeddingModel,
                                rerankerModel: rerankerModel
                            )
                        }
                        if self.throttleDelayMs > 0 {
                            try await Task.sleep(nanoseconds: UInt64(self.throttleDelayMs) * 1_000_000)
                        }
                        return result
                    } catch is CancellationError {
                        // Don't synthesize a "warning" record for a cancelled task –
                        // cancellation isn't a result, it's an absence. Mark the row
                        // explicitly so the user can see which files were skipped.
                        await self.logger.log(
                            level: "WARNING",
                            file: URL(fileURLWithPath: document.sourceFile).lastPathComponent,
                            phase: "INFERENCE",
                            message: "cancelled by user"
                        )
                        var cancelled = SHExtractionResult.empty(sourceFile: document.sourceFile)
                        cancelled.warnings = ["Přerušeno uživatelem"]
                        return cancelled
                    } catch {
                        await self.logger.log(
                            level: "ERROR",
                            file: URL(fileURLWithPath: document.sourceFile).lastPathComponent,
                            phase: "INFERENCE",
                            message: error.localizedDescription
                        )
                        var fallback = SHExtractionResult.empty(sourceFile: document.sourceFile)
                        fallback.warnings = [error.localizedDescription]
                        return fallback
                    }
                }
            }

            var partial: [SHExtractionResult] = []
            partial.reserveCapacity(total)
            for await item in group {
                partial.append(item)
                completed += 1
                await onProgress(completed, total, .documents)
            }
            return partial
        }

        return results.sorted { $0.source_file < $1.source_file }
    }

    // MARK: – Consolidate mode

    /// Sends all documents concatenated in a single request. Returns a single
    /// `SHExtractionResult` with the aggregated raw response. Useful when the user's
    /// prompt asks the model to produce one JSON array across the whole batch.
    private func runConsolidated(
        documents: [SHCachedDocument],
        prompts: [SHPromptTemplate],
        server: SHServerConfig,
        inferenceModel: String,
        onProgress: @escaping @Sendable (_ completed: Int, _ total: Int, _ kind: SHExtractionProgressKind) async -> Void
    ) async -> [SHExtractionResult] {
        let total = documents.count
        await onProgress(0, total, .documents)

        guard let prompt = prompts.first else {
            var empty = SHExtractionResult.empty(sourceFile: "Consolidated (\(total) dokumentů)")
            empty.warnings = ["Prompt není zadaný"]
            await onProgress(total, total, .documents)
            return [empty]
        }

        // Concatenate all documents with clearly labeled separators so the model can
        // identify boundaries and cross-reference them.
        let combined = documents.enumerated().map { index, doc in
            let name = URL(fileURLWithPath: doc.sourceFile).lastPathComponent
            return "=== Dokument #\(index + 1): \(name) ===\n\(doc.cleanedText)"
        }.joined(separator: "\n\n")

        let user = """
        \(prompt.content)

        Vstupní dokumenty (\(total)):
        \(combined)
        """

        let start = Date()
        let sourceLabel = "Consolidated (\(total) dokumentů)"

        // Build the cache key early so we can short-circuit before the expensive
        // preflight token counting. Order matters: cache lookup first → preflight
        // second. A cached response is valid regardless of today's token budget
        // (it was already produced by a previous run that fit).
        let cacheKey = SHInferenceCache.makeKey(
            systemPrompt: Self.extractionSystemPrompt,
            prompt: prompt.content,
            cleanerVersion: SHTextCleaningService.version,
            documentHashes: documents.map(\.fileHash),
            model: inferenceModel,
            embeddingModel: "",
            modeTag: "consolidate"
        )

        do {
            if !bypassInferenceCache,
               let cache = inferenceCache,
               let hit = await cache.load(key: cacheKey) {
                incrementCacheHits()
                await logger.log(
                    file: "<consolidated>",
                    phase: "INFERENCE-CACHE",
                    message: "hit (\(hit.count) chars)"
                )
                var result = bestEffortDecode(json: hit, sourceFile: sourceLabel)
                result.source_file = sourceLabel
                await onProgress(total, total, .documents)
                return [result]
            }

            // Pre-flight: measure token cost. When the payload doesn't fit into the
            // model's context, switch to **map-reduce** instead of failing.
            //
            // Two sources of truth, in priority order:
            //   1. LM Studio's native `/api/v0/tokenize` → exact count using the
            //      loaded model's tokenizer. Avoids the "fits in estimate, hangs
            //      in llama.cpp" scenario that motivated this refactor.
            //   2. Character-based fallback (`ceil(chars / 3)`) for non-LM-Studio
            //      backends or older versions without the endpoint.
            let totalChars = user.count + Self.extractionSystemPrompt.count
            let tokenBudget = Int(Double(modelContextTokens) * Self.consolidateInputBudget)
            let estimatedTokens: Int
            let tokenSource: String
            if let exact = await lmClient.countTokens(
                server: server,
                model: inferenceModel,
                text: Self.extractionSystemPrompt + "\n" + user
            ) {
                estimatedTokens = exact
                tokenSource = "measured"
            } else {
                estimatedTokens = Int(ceil(Double(totalChars) / Self.czechCharsPerToken))
                tokenSource = "estimated"
            }
            if estimatedTokens > tokenBudget {
                await logger.log(
                    level: "INFO",
                    file: "<consolidated>",
                    phase: "PREFLIGHT",
                    message: "\(tokenSource) \(estimatedTokens)t > budget \(tokenBudget)t → switching to map-reduce"
                )
                return await runMapReduce(
                    documents: documents,
                    prompt: prompt,
                    server: server,
                    inferenceModel: inferenceModel,
                    sourceLabel: sourceLabel,
                    tokenBudget: tokenBudget,
                    onProgress: onProgress
                )
            } else {
                await logger.log(
                    level: "INFO",
                    file: "<consolidated>",
                    phase: "PREFLIGHT",
                    message: "\(tokenSource) \(estimatedTokens)t ≤ budget \(tokenBudget)t → single request"
                )
            }

            // Explicit cancellation point right before the multi-minute LM call.
            try Task.checkCancellation()

            let json = try await lmClient.chatJSON(
                server: server,
                model: inferenceModel,
                systemPrompt: Self.extractionSystemPrompt,
                userPrompt: user
            )
            let duration = Date().timeIntervalSince(start) * 1000.0
            await benchmark.addInference(durationMs: duration)
            await logger.log(
                file: "<consolidated>",
                phase: "INFERENCE",
                message: "\(total) docs, prompt=\(prompt.id)",
                durationMs: duration
            )

            // Best-effort canonical decode; on mismatch the raw output is the result.
            var result = bestEffortDecode(json: json, sourceFile: sourceLabel)
            result.source_file = sourceLabel

            // Persist to cache only when we have a usable response. Empty string
            // from a broken inference isn't worth caching – next run should retry.
            if let cache = inferenceCache, !json.isEmpty {
                await cache.save(
                    key: cacheKey,
                    response: json,
                    model: inferenceModel,
                    modeTag: "consolidate"
                )
            }

            await onProgress(total, total, .documents)
            return [result]
        } catch is CancellationError {
            await logger.log(
                level: "WARNING",
                file: "<consolidated>",
                phase: "INFERENCE",
                message: "cancelled by user"
            )
            var cancelled = SHExtractionResult.empty(sourceFile: sourceLabel)
            cancelled.warnings = ["Přerušeno uživatelem"]
            await onProgress(total, total, .documents)
            return [cancelled]
        } catch {
            await logger.log(
                level: "ERROR",
                file: "<consolidated>",
                phase: "INFERENCE",
                message: error.localizedDescription
            )
            var fallback = SHExtractionResult.empty(sourceFile: sourceLabel)
            fallback.warnings = [error.localizedDescription]
            await onProgress(total, total, .documents)
            return [fallback]
        }
    }

    // MARK: – Map-reduce (CONSOLIDATE with over-budget input)

    /// Splits `documents` into batches that fit the model's context, runs each
    /// batch through the user's prompt (MAP), then merges the partial outputs
    /// with one final reduce call. Progress reports N+1 steps where N = batches.
    ///
    /// Each batch and the reduce pass participates in the inference cache, so
    /// re-running the same prompt on the same docs only pays for the parts that
    /// actually changed.
    private func runMapReduce(
        documents: [SHCachedDocument],
        prompt: SHPromptTemplate,
        server: SHServerConfig,
        inferenceModel: String,
        sourceLabel: String,
        tokenBudget: Int,
        onProgress: @escaping @Sendable (_ completed: Int, _ total: Int, _ kind: SHExtractionProgressKind) async -> Void
    ) async -> [SHExtractionResult] {
        // Per-batch char budget = token budget × chars-per-token minus overhead
        // for the wrapper prompt. Overhead estimate is generous (double the
        // prompt length) to avoid edge-case overflows.
        let overheadChars = 2 * (prompt.content.count + Self.extractionSystemPrompt.count + 300)
        let perBatchBudget = max(
            1_500,
            Int(Double(tokenBudget) * Self.czechCharsPerToken) - overheadChars
        )

        // Greedy packing: accumulate docs until the next one would overflow,
        // then start a new batch. A single oversized doc gets its own batch
        // (LM call will likely fail, but the user sees which doc caused it).
        var batches: [[SHCachedDocument]] = []
        var current: [SHCachedDocument] = []
        var currentSize = 0
        let docSeparatorOverhead = 80 // "=== Dokument #N: name ===\n\n"
        for doc in documents {
            let docSize = doc.cleanedText.count + docSeparatorOverhead
            if currentSize + docSize > perBatchBudget, !current.isEmpty {
                batches.append(current)
                current = []
                currentSize = 0
            }
            current.append(doc)
            currentSize += docSize
        }
        if !current.isEmpty { batches.append(current) }

        let totalSteps = batches.count + 1
        await logger.log(
            file: "<map-reduce>",
            phase: "PLAN",
            message: "\(documents.count) dok → \(batches.count) dávek + 1 reduce (\(totalSteps) LM volání)"
        )
        await onProgress(0, totalSteps, .lmSteps)

        // MAP: each batch produces a partial output in the user's schema. Batches
        // are independent, so they can run concurrently under the same inference
        // semaphore used by per-document extraction.
        let partials: [String]
        do {
            var completedMaps = 0
            let batchCount = batches.count
            partials = try await withThrowingTaskGroup(
                of: (index: Int, partial: String).self,
                returning: [String].self
            ) { group in
                for (index, batch) in batches.enumerated() {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let partial = try await self.inferenceQueue.run {
                                try await self.runMapBatch(
                                    batch: batch,
                                    batchIndex: index + 1,
                                    batchCount: batchCount,
                                    prompt: prompt,
                                    server: server,
                                    inferenceModel: inferenceModel
                                )
                            }
                            return (index, partial)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            await self.logger.log(
                                level: "ERROR",
                                file: "<map-reduce>",
                                phase: "MAP[\(index + 1)/\(batchCount)]",
                                message: error.localizedDescription
                            )
                            return (index, "[CHYBA dávky \(index + 1): \(error.localizedDescription)]")
                        }
                    }
                }

                var ordered = Array(repeating: "", count: batches.count)
                for try await item in group {
                    ordered[item.index] = item.partial
                    completedMaps += 1
                    await onProgress(completedMaps, totalSteps, .lmSteps)
                }
                return ordered
            }
        } catch is CancellationError {
            var cancelled = SHExtractionResult.empty(sourceFile: sourceLabel)
            cancelled.warnings = ["Přerušeno uživatelem během map-reduce"]
            await onProgress(totalSteps, totalSteps, .lmSteps)
            return [cancelled]
        } catch {
            var failed = SHExtractionResult.empty(sourceFile: sourceLabel)
            failed.warnings = ["Map-reduce selhal během MAP fáze: \(error.localizedDescription)"]
            await onProgress(totalSteps, totalSteps, .lmSteps)
            return [failed]
        }

        // REDUCE: merge partials into a single output in the same schema.
        do {
            try Task.checkCancellation()
            let finalResponse = try await runReduce(
                partials: partials,
                originalPrompt: prompt,
                server: server,
                inferenceModel: inferenceModel,
                batchCount: batches.count,
                documentHashes: documents.map(\.fileHash)
            )
            var result = bestEffortDecode(json: finalResponse, sourceFile: sourceLabel)
            result.source_file = sourceLabel
            result.warnings.insert(
                "Map-reduce: vstup překračoval kontext modelu, proto byl rozdělen do \(batches.count) dávek a spojen finálním reduce voláním.",
                at: 0
            )
            await onProgress(totalSteps, totalSteps, .lmSteps)
            return [result]
        } catch is CancellationError {
            var cancelled = SHExtractionResult.empty(sourceFile: sourceLabel)
            cancelled.warnings = ["Přerušeno uživatelem během reduce fáze map-reduce"]
            await onProgress(totalSteps, totalSteps, .lmSteps)
            return [cancelled]
        } catch {
            await logger.log(
                level: "ERROR",
                file: "<map-reduce>",
                phase: "REDUCE",
                message: error.localizedDescription
            )
            // Reduce failed – return concatenated partials as a last resort so the
            // user at least has the per-batch data.
            let fallbackRaw = partials.enumerated()
                .map { "=== Dávka #\($0.offset + 1)/\(batches.count) ===\n\($0.element)" }
                .joined(separator: "\n\n")
            var fallback = SHExtractionResult.empty(sourceFile: sourceLabel)
            fallback.rawResponse = fallbackRaw
            fallback.warnings = [
                "Map-reduce: final reduce selhal (\(error.localizedDescription)). V rawResponse jsou jednotlivé dávky oddělené markerem === Dávka #N ===.",
            ]
            await onProgress(totalSteps, totalSteps, .lmSteps)
            return [fallback]
        }
    }

    /// Runs one MAP batch: same user prompt + a prefix note "this is batch N/M".
    private func runMapBatch(
        batch: [SHCachedDocument],
        batchIndex: Int,
        batchCount: Int,
        prompt: SHPromptTemplate,
        server: SHServerConfig,
        inferenceModel: String
    ) async throws -> String {
        let combined = batch.enumerated().map { index, doc in
            let name = URL(fileURLWithPath: doc.sourceFile).lastPathComponent
            return "=== Dokument #\(index + 1): \(name) ===\n\(doc.cleanedText)"
        }.joined(separator: "\n\n")

        let user = """
        [Toto je dávka #\(batchIndex) z \(batchCount). Zpracuj jen přiložené dokumenty a vrať výstup ve stejném formátu, jako bys měl jen tyto dokumenty. Deduplikace napříč dávkami proběhne v další fázi.]

        \(prompt.content)

        Vstupní dokumenty v této dávce (\(batch.count)):
        \(combined)
        """

        // Cache per-batch so partial progress survives cancellation/restart.
        let cacheKey = SHInferenceCache.makeKey(
            systemPrompt: Self.extractionSystemPrompt,
            prompt: prompt.content,
            cleanerVersion: SHTextCleaningService.version,
            documentHashes: batch.map(\.fileHash),
            model: inferenceModel,
            embeddingModel: "",
            modeTag: "consolidate-map"
        )

        if !bypassInferenceCache,
           let cache = inferenceCache,
           let hit = await cache.load(key: cacheKey) {
            incrementCacheHits()
            await logger.log(
                file: "<map-reduce>",
                phase: "MAP[\(batchIndex)/\(batchCount)]",
                message: "cache hit (\(hit.count) chars)"
            )
            return hit
        }

        let start = Date()
        let json = try await lmClient.chatJSON(
            server: server,
            model: inferenceModel,
            systemPrompt: Self.extractionSystemPrompt,
            userPrompt: user
        )
        let duration = Date().timeIntervalSince(start) * 1000.0
        await benchmark.addInference(durationMs: duration)
        await logger.log(
            file: "<map-reduce>",
            phase: "MAP[\(batchIndex)/\(batchCount)]",
            message: "\(batch.count) dok, \(json.count) char",
            durationMs: duration
        )

        if let cache = inferenceCache, !json.isEmpty {
            await cache.save(key: cacheKey, response: json, model: inferenceModel, modeTag: "consolidate-map")
        }
        return json
    }

    /// Runs the REDUCE pass: feed all MAP partials back to the model with the
    /// original prompt and ask for a single merged, deduplicated output.
    private func runReduce(
        partials: [String],
        originalPrompt: SHPromptTemplate,
        server: SHServerConfig,
        inferenceModel: String,
        batchCount: Int,
        documentHashes: [String]
    ) async throws -> String {
        let joined = partials.enumerated()
            .map { "=== Výstup dávky #\($0.offset + 1)/\(batchCount) ===\n\($0.element)" }
            .joined(separator: "\n\n")

        let user = """
        [Dříve jsi zpracoval stejnou úlohu v \(batchCount) dávkách. Níže jsou jejich dílčí výstupy. Spoj je do jediného finálního výstupu ve stejném formátu – dedupli­kuj záznamy (pokud stejný subjekt přišel ve více dávkách, vyber nejúplnější/nejspolehlivější hodnoty), zachovej formát výstupu definovaný úlohou. Nevracej komentáře ani metainformace, pouze finální výstup.]

        Původní zadání:
        \(originalPrompt.content)

        Dílčí výstupy:
        \(joined)
        """

        // Reduce has its own cache slot, keyed on the prompt + all source docs
        // + batch count, so the full map-reduce is reproducible.
        let cacheKey = SHInferenceCache.makeKey(
            systemPrompt: Self.extractionSystemPrompt,
            prompt: originalPrompt.content,
            cleanerVersion: SHTextCleaningService.version,
            documentHashes: documentHashes + ["batches=\(batchCount)"],
            model: inferenceModel,
            embeddingModel: "",
            modeTag: "consolidate-reduce"
        )

        if !bypassInferenceCache,
           let cache = inferenceCache,
           let hit = await cache.load(key: cacheKey) {
            incrementCacheHits()
            await logger.log(
                file: "<map-reduce>",
                phase: "REDUCE",
                message: "cache hit (\(hit.count) chars)"
            )
            return hit
        }

        let start = Date()
        let json = try await lmClient.chatJSON(
            server: server,
            model: inferenceModel,
            systemPrompt: Self.extractionSystemPrompt,
            userPrompt: user
        )
        let duration = Date().timeIntervalSince(start) * 1000.0
        await benchmark.addInference(durationMs: duration)
        await logger.log(
            file: "<map-reduce>",
            phase: "REDUCE",
            message: "\(batchCount) partials, \(json.count) char",
            durationMs: duration
        )

        if let cache = inferenceCache, !json.isEmpty {
            await cache.save(key: cacheKey, response: json, model: inferenceModel, modeTag: "consolidate-reduce")
        }
        return json
    }

    // MARK: – Per-document

    private func extractOne(
        document: SHCachedDocument,
        prompts: [SHPromptTemplate],
        mode: SHExtractionMode,
        server: SHServerConfig,
        inferenceModel: String,
        embeddingModel: String,
        rerankerModel: String
    ) async throws -> SHExtractionResult {
        guard !prompts.isEmpty else {
            var empty = SHExtractionResult.empty(sourceFile: document.sourceFile)
            empty.warnings = ["Prompt není zadaný"]
            return empty
        }

        var result = SHExtractionResult.empty(sourceFile: document.sourceFile)

        let fileLabel = URL(fileURLWithPath: document.sourceFile).lastPathComponent

        for prompt in prompts {
            try Task.checkCancellation()

            let start = Date()
            // Inference cache lookup. Key includes every input that influences
            // what the model sees: system prompt, user prompt, cleaner version,
            // file hash, inference model, embedding model (SEARCH only), mode tag.
            let cacheKey = SHInferenceCache.makeKey(
                systemPrompt: Self.extractionSystemPrompt,
                prompt: prompt.content,
                cleanerVersion: SHTextCleaningService.version,
                documentHashes: [document.fileHash],
                model: inferenceModel,
                embeddingModel: mode == .search ? embeddingModel : "",
                rerankerModel: mode == .search ? rerankerModel : "",
                modeTag: mode.rawValue
            )

            let json: String
            if !bypassInferenceCache,
               let cache = inferenceCache,
               let hit = await cache.load(key: cacheKey) {
                incrementCacheHits()
                json = hit
                await logger.log(
                    file: fileLabel,
                    phase: "INFERENCE-CACHE",
                    message: "hit (\(hit.count) chars)"
                )
            } else {
                let context = try await contextForPrompt(
                    prompt,
                    document: document,
                    mode: mode,
                    server: server,
                    embeddingModel: embeddingModel,
                    rerankerModel: rerankerModel
                )

                let user = """
                \(prompt.content)

                Zdrojový soubor: \(document.sourceFile)

                Text dokumentu:
                \(context)
                """

                // Explicit cancellation point before the multi-minute LM call.
                // URLSession would propagate cancellation once it starts, but this
                // catches cancellation that arrived while waiting in the queue.
                try Task.checkCancellation()

                json = try await lmClient.chatJSON(
                    server: server,
                    model: inferenceModel,
                    systemPrompt: Self.extractionSystemPrompt,
                    userPrompt: user
                )
                // Only cache non-empty responses; empty response typically means
                // the model failed mid-stream and caching that would make the next
                // run silently return the broken output too.
                if let cache = inferenceCache, !json.isEmpty {
                    await cache.save(
                        key: cacheKey,
                        response: json,
                        model: inferenceModel,
                        modeTag: mode.rawValue
                    )
                }
            }

            // Best-effort: try to parse into the canonical schema. If it fits (rare,
            // only when the user's prompt happens to match our built-in shape), great –
            // otherwise we drop into "custom schema" mode and simply preserve the raw
            // response. Repair flow is intentionally NOT invoked: for custom user
            // prompts it fabricates empty canonical fields and wastes inference time.
            let partial = bestEffortDecode(
                json: json,
                sourceFile: document.sourceFile
            )
            result.merge(with: partial)

            let duration = Date().timeIntervalSince(start) * 1000.0
            await benchmark.addInference(durationMs: duration)
            await logger.log(
                file: fileLabel,
                phase: "INFERENCE",
                message: prompt.id,
                durationMs: duration
            )
        }

        return result
    }

    // MARK: – Context selection

    private func contextForPrompt(
        _ prompt: SHPromptTemplate,
        document: SHCachedDocument,
        mode: SHExtractionMode,
        server: SHServerConfig,
        embeddingModel: String,
        rerankerModel: String
    ) async throws -> String {
        switch mode {
        case .fast, .consolidate:
            // `.consolidate` is dispatched in `run()` and never reaches this switch;
            // `.fast` just uses the full cleaned text without RAG.
            return document.cleanedText
        case .search:
            let chunks = chunk(document.cleanedText, size: Self.searchChunkSize, overlap: Self.searchChunkOverlap)
            guard !chunks.isEmpty else { return document.cleanedText }

            let fileLabel = URL(fileURLWithPath: document.sourceFile).lastPathComponent

            guard !embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await logger.log(
                    level: "WARNING",
                    file: fileLabel,
                    phase: "EMBEDDING",
                    message: "embedding model not configured, falling back to first \(Self.searchTopChunks) chunks"
                )
                return topChunksFallback(chunks)
            }

            // Query embedding: required; fallback to top-N if it fails. The query
            // vector only depends on prompt + embedding model, so cache it across
            // all documents in this run.
            let queryEmbedding: [Double]
            do {
                queryEmbedding = try await cachedEmbedding(server: server, model: embeddingModel, input: prompt.content)
            } catch {
                await logger.log(
                    level: "WARNING",
                    file: fileLabel,
                    phase: "EMBEDDING",
                    message: "query embedding failed (\(error.localizedDescription)), fallback to top chunks"
                )
                return topChunksFallback(chunks)
            }
            if queryEmbedding.isEmpty {
                return topChunksFallback(chunks)
            }

            let chunkEmbeddings: [(index: Int, embedding: [Double])]
            do {
                chunkEmbeddings = try await cachedEmbeddings(
                    server: server,
                    model: embeddingModel,
                    inputs: chunks
                )
            } catch {
                await logger.log(
                    level: "WARNING",
                    file: fileLabel,
                    phase: "EMBEDDING",
                    message: "batch chunk embedding failed (\(error.localizedDescription)), falling back to parallel single requests"
                )
                chunkEmbeddings = await chunkEmbeddingsIndividually(
                    chunks: chunks,
                    server: server,
                    embeddingModel: embeddingModel,
                    fileLabel: fileLabel
                )
            }

            let scored = chunkEmbeddings.compactMap { item -> (chunk: String, score: Double)? in
                let score = cosineSimilarity(queryEmbedding, item.embedding)
                guard score.isFinite else { return nil }
                return (chunks[item.index], score)
            }

            if scored.isEmpty {
                return topChunksFallback(chunks)
            }
            let ranked = scored
                .sorted { $0.score > $1.score }
            let reranker = rerankerModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reranker.isEmpty {
                let candidates = Array(ranked.prefix(Self.searchRerankCandidates))
                let candidateTexts = candidates.map(\.chunk)
                do {
                    let reranked = try await lmClient.rerank(
                        server: server,
                        model: reranker,
                        query: prompt.content,
                        documents: candidateTexts,
                        topN: Self.searchTopChunks
                    )
                    let chunks = reranked
                        .sorted { $0.score > $1.score }
                        .prefix(Self.searchTopChunks)
                        .map { candidateTexts[$0.index] }
                    if !chunks.isEmpty {
                        return chunks.joined(separator: "\n\n")
                    }
                } catch {
                    await logger.log(
                        level: "WARNING",
                        file: fileLabel,
                        phase: "RERANK",
                        message: "rerank failed (\(error.localizedDescription)), using embedding ranking"
                    )
                }
            }

            return ranked
                .prefix(Self.searchTopChunks)
                .map(\.chunk)
                .joined(separator: "\n\n")
        }
    }

    private func topChunksFallback(_ chunks: [String]) -> String {
        chunks.prefix(Self.searchTopChunks).joined(separator: "\n\n")
    }

    private func cachedEmbedding(
        server: SHServerConfig,
        model: String,
        input: String
    ) async throws -> [Double] {
        let key = SHEmbeddingCache.makeKey(server: server, model: model, input: input)
        if let cached = await embeddingRunCache.load(key: key) {
            return cached
        }
        if let persistent = await embeddingCache?.load(key: key) {
            await embeddingRunCache.save(persistent, key: key)
            return persistent
        }
        let embedding = try await lmClient.embedding(server: server, model: model, input: input)
        await embeddingRunCache.save(embedding, key: key)
        await embeddingCache?.save(key: key, embedding: embedding, model: model)
        return embedding
    }

    private func cachedEmbeddings(
        server: SHServerConfig,
        model: String,
        inputs: [String]
    ) async throws -> [(index: Int, embedding: [Double])] {
        var output: [(index: Int, embedding: [Double])] = []
        output.reserveCapacity(inputs.count)

        var missingIndexes: [Int] = []
        var missingInputs: [String] = []
        for (index, input) in inputs.enumerated() {
            let key = SHEmbeddingCache.makeKey(server: server, model: model, input: input)
            if let cached = await embeddingRunCache.load(key: key) {
                output.append((index, cached))
            } else if let persistent = await embeddingCache?.load(key: key) {
                await embeddingRunCache.save(persistent, key: key)
                output.append((index, persistent))
            } else {
                missingIndexes.append(index)
                missingInputs.append(input)
            }
        }

        if !missingInputs.isEmpty {
            let embeddings = try await lmClient.embeddings(server: server, model: model, inputs: missingInputs)
            for (offset, embedding) in embeddings.enumerated() {
                let sourceIndex = missingIndexes[offset]
                let key = SHEmbeddingCache.makeKey(server: server, model: model, input: inputs[sourceIndex])
                await embeddingRunCache.save(
                    embedding,
                    key: key
                )
                await embeddingCache?.save(key: key, embedding: embedding, model: model)
                output.append((sourceIndex, embedding))
            }
        }

        return output.sorted { $0.index < $1.index }
    }

    private func chunkEmbeddingsIndividually(
        chunks: [String],
        server: SHServerConfig,
        embeddingModel: String,
        fileLabel: String
    ) async -> [(index: Int, embedding: [Double])] {
        await withTaskGroup(
            of: (Int, [Double]?).self,
            returning: [(index: Int, embedding: [Double])].self
        ) { group in
            for (index, text) in chunks.enumerated() {
                group.addTask {
                    do {
                        let embedding = try await self.cachedEmbedding(server: server, model: embeddingModel, input: text)
                        return (index, embedding)
                    } catch {
                        await self.logger.log(
                            level: "WARNING",
                            file: fileLabel,
                            phase: "EMBEDDING",
                            message: "chunk #\(index) embedding failed (\(error.localizedDescription))"
                        )
                        return (index, nil)
                    }
                }
            }

            var collected: [(index: Int, embedding: [Double])] = []
            collected.reserveCapacity(chunks.count)
            for await (index, embedding) in group {
                guard let embedding, !embedding.isEmpty else { continue }
                collected.append((index, embedding))
            }
            return collected.sorted { $0.index < $1.index }
        }
    }

    // MARK: – Validation

    /// Best-effort decode of an LLM response. If the JSON happens to match the built-in
    /// canonical schema (rare – only when the user's prompt explicitly targets it) the
    /// decoded result is returned. Otherwise an empty canonical result is returned with
    /// `rawResponse` filled with the exact string the LLM produced. In either case the
    /// raw response is preserved. No repair call is issued: repair fabricates canonical
    /// fields for custom-schema responses and wastes inference time.
    private func bestEffortDecode(json: String, sourceFile: String) -> SHExtractionResult {
        if var decoded = try? schemaValidator.decodeValidated(json: json) {
            if decoded.source_file.isEmpty {
                decoded.source_file = sourceFile
            }
            decoded.rawResponse = json
            return decoded
        }
        var result = SHExtractionResult.empty(sourceFile: sourceFile)
        result.rawResponse = json
        return result
    }

    // MARK: – Helpers

    private func chunk(_ text: String, size: Int, overlap: Int) -> [String] {
        precondition(size > 0, "chunk size must be positive")
        precondition(overlap < size, "overlap must be smaller than size, otherwise chunking degenerates to O(N) per character")

        let chars = Array(text)
        guard !chars.isEmpty else { return [] }

        var chunks: [String] = []
        var index = 0
        while index < chars.count {
            let end = min(index + size, chars.count)
            chunks.append(String(chars[index..<end]))
            if end == chars.count { break }
            index = max(end - overlap, index + 1)
        }
        return chunks
    }

    /// Cosine similarity with NaN/Inf guards. Returns 0 for degenerate inputs so the
    /// result is safe to sort by without violating strict weak ordering.
    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<a.count {
            let x = a[i]
            let y = b[i]
            guard x.isFinite, y.isFinite else { return 0 }
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        let value = dot / (sqrt(normA) * sqrt(normB))
        return value.isFinite ? value : 0
    }
}
