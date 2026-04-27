import Foundation
import CryptoKit

final class SHPreprocessingPipeline {
    struct Output {
        let cachedDocuments: [SHCachedDocument]
        let counters: SHPipelineCounters
    }

    private let scanner = SHFileScanService()
    private let parser = SHPDFParser()
    private let cleaner = SHTextCleaningService()
    private let ocrProvider: SHOCRProviding
    private let cacheManager: SHCacheManager
    private let logger: SHProcessingLogger
    private let benchmark: SHBenchmarkService
    private let queue: SHQueueManager
    private let preprocessingSignature: String

    init(
        ocrProvider: SHOCRProviding,
        cacheManager: SHCacheManager,
        logger: SHProcessingLogger,
        benchmark: SHBenchmarkService,
        maxConcurrentWorkers: Int,
        preprocessingSignature: String = ""
    ) {
        self.ocrProvider = ocrProvider
        self.cacheManager = cacheManager
        self.logger = logger
        self.benchmark = benchmark
        self.queue = SHQueueManager(maxConcurrent: maxConcurrentWorkers)
        self.preprocessingSignature = preprocessingSignature
    }

    func run(
        inputFolder: URL,
        onCounters: @escaping @Sendable (SHPipelineCounters) async -> Void
    ) async -> Output {
        let scanStart = Date()
        let files = scanner.recursivePDFs(in: inputFolder)
        var counters = SHPipelineCounters(foundPDFs: files.count)
        await onCounters(counters)
        await benchmark.addScan(durationMs: Date().timeIntervalSince(scanStart) * 1000.0, docs: files.count)

        var output: [SHCachedDocument] = []

        await withTaskGroup(of: SHCachedDocument?.self) { group in
            for file in files {
                group.addTask {
                    do {
                        return try await self.queue.run {
                            try await self.processOne(fileURL: file)
                        }
                    } catch {
                        await self.logger.log(level: "ERROR", file: file.lastPathComponent, phase: "PREPROCESS", message: error.localizedDescription)
                        return nil
                    }
                }
            }

            for await item in group {
                guard let item else { continue }
                output.append(item)
                counters.completed += 1
                // `remaining` is now computed from (foundPDFs - completed) on the
                // struct itself, no manual sync needed.
                if item.metadata.usedOCR { counters.newlyOCRed += 1 }
                await onCounters(counters)
            }
        }

        counters.cachedDocs = await cacheManager.count()
        await onCounters(counters)

        return Output(cachedDocuments: output.sorted { $0.sourceFile < $1.sourceFile }, counters: counters)
    }

    private func processOne(fileURL: URL) async throws -> SHCachedDocument {
        try Task.checkCancellation()

        let hashStart = Date()
        let fileHash = try scanner.sha256(of: fileURL)
        let hash = cacheHash(fileHash: fileHash)
        await logger.log(file: fileURL.lastPathComponent, phase: "HASH", message: "completed", durationMs: Date().timeIntervalSince(hashStart) * 1000.0)

        if let cached = await cacheManager.load(hash: hash) {
            await logger.log(file: fileURL.lastPathComponent, phase: "CACHE", message: "hit")
            if cached.sourceFile == fileURL.path {
                return cached
            }
            // File was renamed/moved; update the cache entry so the new path
            // survives in the on-disk cache too (was in-memory only before).
            var updated = cached
            updated.sourceFile = fileURL.path
            await cacheManager.save(updated)
            return updated
        }

        await logger.log(file: fileURL.lastPathComponent, phase: "CACHE", message: "miss")

        let parseStart = Date()
        let parsed = parser.parse(fileURL)
        await benchmark.addTextExtraction(durationMs: Date().timeIntervalSince(parseStart) * 1000.0, pages: parsed.pageCount)

        let rawPages: [String]
        let usedOCR: Bool

        if parsed.hasTextLayer {
            rawPages = parsed.rawPages
            usedOCR = false
            await logger.log(file: fileURL.lastPathComponent, phase: "TEXT", message: "extracted", durationMs: Date().timeIntervalSince(parseStart) * 1000.0)
        } else {
            let ocrStart = Date()
            rawPages = try await ocrProvider.extractText(from: fileURL)
            usedOCR = true
            let duration = Date().timeIntervalSince(ocrStart) * 1000.0
            await benchmark.addOCR(durationMs: duration, pages: max(rawPages.count, 1))
            await logger.log(file: fileURL.lastPathComponent, phase: "OCR", message: "completed", durationMs: duration)
        }

        let cleanedPages = cleaner.cleanPages(rawPages)
        let rawText = rawPages.joined(separator: "\n\n")
        let cleanedText = cleanedPages.map(\.cleanedText).joined(separator: "\n\n")

        // Count pages exactly once per document (either from the PDF page count or
        // from OCR page count if the PDF had no text layer).
        let effectivePageCount = parsed.pageCount == 0 ? cleanedPages.count : parsed.pageCount
        await benchmark.recordPages(effectivePageCount)

        let cached = SHCachedDocument(
            sourceFile: fileURL.path,
            fileHash: hash,
            processedAt: Date(),
            rawText: rawText,
            cleanedText: cleanedText,
            pages: cleanedPages,
            metadata: SHDocumentMetadata(pageCount: effectivePageCount, usedOCR: usedOCR, hasTextLayer: parsed.hasTextLayer)
        )

        await cacheManager.save(cached)
        await logger.log(file: fileURL.lastPathComponent, phase: "CACHE", message: "saved")
        return cached
    }

    private func cacheHash(fileHash: String) -> String {
        let signature = preprocessingSignature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signature.isEmpty else { return fileHash }
        var hasher = SHA256()
        hasher.update(data: Data(fileHash.utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data(signature.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
