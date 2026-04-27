import Foundation
import AppKit
import Quartz
import Vision
import NaturalLanguage

final class ExtractionService: ExtractionServicing {
    private struct ODLBlock: Hashable {
        let page: Int?
        let type: String?
        let text: String
    }

    var openDataLoaderPath: String = ""
    var useOpenDataLoader: Bool = false
    private var textCache: [String: String] = [:]
    private var odlTextCache: [String: String] = [:]
    private var odlBlocksCache: [String: [ODLBlock]] = [:]
    private let cacheLock = NSLock()

    func clearCache() {
        cacheLock.lock()
        textCache.removeAll()
        odlTextCache.removeAll()
        odlBlocksCache.removeAll()
        cacheLock.unlock()
    }

    func prefetchPDFText(paths: [String]) {
        guard useOpenDataLoader, !openDataLoaderPath.isEmpty else { return }
        var seen = Set<String>()
        let pdfPaths = paths.filter {
            guard URL(fileURLWithPath: $0).pathExtension.lowercased() == "pdf" else { return false }
            return seen.insert($0).inserted
        }
        guard !pdfPaths.isEmpty else { return }

        guard let results = extractBatchWithOpenDataLoader(pdfPaths: pdfPaths) else { return }

        cacheLock.lock()
        for (path, result) in results {
            if !result.text.isEmpty {
                odlTextCache[path] = result.text
            }
            if !result.blocks.isEmpty {
                odlBlocksCache[path] = result.blocks
            }
        }
        cacheLock.unlock()
    }

    func extractStructuredChunks(from path: String, maxChunkCharacters: Int) -> [String]? {
        guard useOpenDataLoader, maxChunkCharacters > 0 else { return nil }
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" else { return nil }

        let blocks: [ODLBlock]
        cacheLock.lock()
        let cachedBlocks = odlBlocksCache[path]
        cacheLock.unlock()

        if let cachedBlocks, !cachedBlocks.isEmpty {
            blocks = cachedBlocks
        } else {
            _ = extractWithOpenDataLoader(pdfPath: path) // fills caches on success
            cacheLock.lock()
            blocks = odlBlocksCache[path] ?? []
            cacheLock.unlock()
        }

        guard !blocks.isEmpty else { return nil }
        return Self.chunkStructured(blocks: blocks, maxChunkCharacters: maxChunkCharacters)
    }

    func readPlainTextFile(at path: String) -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOfFile: path, usedEncoding: &encoding) {
            return text
        }

        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    func detectLanguage(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1000)))
        return recognizer.dominantLanguage?.rawValue ?? "unknown"
    }

    func extractText(from path: String) -> String {
        extractText(from: path, ocrResolutionWidth: 1000)
    }

    func extractText(from path: String, ocrResolutionWidth: CGFloat) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "pdf" && useOpenDataLoader {
            cacheLock.lock()
            let cachedODL = odlTextCache[path]
            cacheLock.unlock()
            if let cachedODL, !cachedODL.isEmpty {
                return cachedODL
            }
        }

        let cacheKey = "\(path)|\(ocrResolutionWidth)"
        cacheLock.lock()
        if let cached = textCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        // Hold lock released — extraction is slow, don't block other threads
        cacheLock.unlock()

        let result = performExtraction(from: path, ocrResolutionWidth: ocrResolutionWidth)

        cacheLock.lock()
        // Another thread may have written while we were extracting — first writer wins
        if textCache[cacheKey] == nil {
            textCache[cacheKey] = result
        }
        cacheLock.unlock()

        return result
    }

    private func performExtraction(from path: String, ocrResolutionWidth: CGFloat) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()

        if AnalysisSupport.plainTextExtensions.contains(ext) {
            return readPlainTextFile(at: path)
        }

        if ext == "pdf" {
            // Try OpenDataLoader if configured and available
            if useOpenDataLoader && !openDataLoaderPath.isEmpty {
                if let odlResult = extractWithOpenDataLoader(pdfPath: path) {
                    return odlResult
                }
                // Fallback to PDFKit if ODL fails
            }
        }

        if ext == "pdf", let pdf = PDFDocument(url: URL(fileURLWithPath: path)) {
            let ocrSize = CGSize(width: ocrResolutionWidth, height: ocrResolutionWidth * 1.414)
            let pageCount = pdf.pageCount

            // Phase 1: Read PDF pages sequentially (PDFPage is NOT thread-safe)
            struct PageData {
                let index: Int
                let text: String?       // usable text layer, or nil → needs OCR
                let cgImage: CGImage?    // rendered image for OCR, or nil
            }

            var pages: [PageData] = []
            for i in 0..<pageCount {
                guard let page = pdf.page(at: i) else {
                    pages.append(PageData(index: i, text: nil, cgImage: nil))
                    continue
                }

                if let pageText = page.string, Self.hasUsableTextLayer(pageText) {
                    pages.append(PageData(index: i, text: pageText, cgImage: nil))
                } else {
                    let image = page.thumbnail(of: ocrSize, for: .mediaBox)
                    let cgImage: CGImage? = image.tiffRepresentation
                        .flatMap { NSBitmapImageRep(data: $0) }?
                        .cgImage
                    pages.append(PageData(index: i, text: nil, cgImage: cgImage))
                }
            }

            // Phase 2: OCR images in parallel (Vision + CGImage is thread-safe)
            let ocrPages = pages.filter { $0.text == nil && $0.cgImage != nil }

            var ocrResults = [Int: String]()
            if !ocrPages.isEmpty {
                let lock = NSLock()
                let group = DispatchGroup()
                let queue = DispatchQueue(label: "ocr.extraction", attributes: .concurrent)

                for pageData in ocrPages {
                    group.enter()
                    queue.async {
                        defer { group.leave() }
                        let ocrText = Self.ocrImage(pageData.cgImage!)
                        lock.lock()
                        ocrResults[pageData.index] = ocrText
                        lock.unlock()
                    }
                }

                group.wait()
            }

            // Phase 3: Assemble result in page order
            var result = ""
            for i in 0..<pageCount {
                if i > 0 {
                    result += "\n\n[[PAGE_BREAK]]\n\n"
                }
                if let text = pages[i].text {
                    result += text
                } else {
                    result += ocrResults[i] ?? ""
                }
            }

            return result
        }

        if ["docx", "doc", "odt", "rtf"].contains(ext) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            task.arguments = ["-convert", "txt", path, "-stdout"]
            let pipe = Pipe()
            task.standardOutput = pipe
            try? task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        if ext == "xlsx" || ext == "xls" {
            return "[Excel soubor detekován – pro analýzu je nutné převést jej na .csv nebo .txt. Obsah není zpracován.]"
        }

        if ext == "pptx" || ext == "ppt" {
            return "[PowerPoint soubor detekován – pro analýzu je nutné převést prezentaci na .pdf. Obsah není zpracován.]"
        }

        return "[Nepodporovaný typ souboru: .\(ext)]"
    }

    // MARK: - Page image extraction for vision models

    func extractPageImages(from path: String, resolutionWidth: CGFloat) -> [Data] {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ext == "pdf", let pdf = PDFDocument(url: URL(fileURLWithPath: path)) else { return [] }

        let height = resolutionWidth * 1.414
        let size = CGSize(width: resolutionWidth, height: height)
        var images: [Data] = []

        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let nsImage = page.thumbnail(of: size, for: .mediaBox)
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65])
            else { continue }
            images.append(jpegData)
        }

        return images
    }

    // MARK: - OpenDataLoader PDF extraction

    private func extractWithOpenDataLoader(pdfPath: String) -> String? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spice-odl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: openDataLoaderPath)
        task.arguments = [pdfPath, "--format", "markdown,json", "--output-dir", tempDir.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0 else { return nil }

        let markdownEntries = Self.files(in: tempDir, withExtension: "md")
        guard let mdFile = Self.bestFileMatch(forPDFPath: pdfPath, entries: markdownEntries),
              let content = try? String(contentsOf: mdFile, encoding: .utf8)
        else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let jsonEntries = Self.files(in: tempDir, withExtension: "json")
        let blocks: [ODLBlock]
        if let jsonFile = Self.bestFileMatch(forPDFPath: pdfPath, entries: jsonEntries),
           let data = try? Data(contentsOf: jsonFile) {
            blocks = Self.parseODLBlocks(data: data)
        } else {
            blocks = []
        }

        cacheLock.lock()
        odlTextCache[pdfPath] = trimmed
        if !blocks.isEmpty {
            odlBlocksCache[pdfPath] = blocks
        }
        cacheLock.unlock()
        return trimmed
    }

    private func extractBatchWithOpenDataLoader(pdfPaths: [String]) -> [String: (text: String, blocks: [ODLBlock])]? {
        guard !pdfPaths.isEmpty else { return [:] }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spice-odl-batch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: openDataLoaderPath)
        task.arguments = pdfPaths + ["--format", "markdown,json", "--output-dir", tempDir.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0 else { return nil }

        let markdownEntries = Self.files(in: tempDir, withExtension: "md")
        guard !markdownEntries.isEmpty else { return nil }
        let jsonEntries = Self.files(in: tempDir, withExtension: "json")

        let markdownMatches = Self.matchBatchOutputs(forPDFPaths: pdfPaths, entries: markdownEntries)
        let jsonMatches = Self.matchBatchOutputs(forPDFPaths: pdfPaths, entries: jsonEntries)

        var results: [String: (text: String, blocks: [ODLBlock])] = [:]
        for pdfPath in pdfPaths {
            let mdFile = markdownMatches[pdfPath]
            let text: String
            if let mdFile, let content = try? String(contentsOf: mdFile, encoding: .utf8) {
                text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = ""
            }

            let jsonFile = jsonMatches[pdfPath]
            let blocks: [ODLBlock]
            if let jsonFile, let data = try? Data(contentsOf: jsonFile) {
                blocks = Self.parseODLBlocks(data: data)
            } else {
                blocks = []
            }

            if !text.isEmpty || !blocks.isEmpty {
                results[pdfPath] = (text: text, blocks: blocks)
            }
        }
        return results.isEmpty ? nil : results
    }

    private static func matchBatchOutputs(forPDFPaths pdfPaths: [String], entries: [URL]) -> [String: URL] {
        guard !pdfPaths.isEmpty, !entries.isEmpty else { return [:] }

        struct Candidate {
            let file: URL
            let score: Int
            let fileSize: Int
        }

        func normalizedBasename(forPath path: String) -> String {
            URL(fileURLWithPath: path)
                .deletingPathExtension()
                .lastPathComponent
                .lowercased()
        }

        func scoring(pdfBaseName: String, fileBaseName: String) -> Int {
            if fileBaseName == pdfBaseName { return 1_000 }
            if fileBaseName.hasPrefix(pdfBaseName) { return 900 }
            if fileBaseName.contains(pdfBaseName) { return 800 }
            if pdfBaseName.contains(fileBaseName) { return 700 }

            let pdfTokens = Set(pdfBaseName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let fileTokens = Set(fileBaseName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let overlap = pdfTokens.intersection(fileTokens).count
            if overlap > 0 {
                return 500 + overlap * 10
            }
            return -1
        }

        var candidatesByPath: [String: [Candidate]] = [:]
        for pdfPath in pdfPaths {
            let baseName = normalizedBasename(forPath: pdfPath)
            let candidates: [Candidate] = entries.compactMap { entry in
                let fileBase = entry.deletingPathExtension().lastPathComponent.lowercased()
                let score = scoring(pdfBaseName: baseName, fileBaseName: fileBase)
                guard score >= 0 else { return nil }
                let fileSize = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return Candidate(file: entry, score: score, fileSize: fileSize)
            }
            .sorted {
                if $0.score == $1.score { return $0.fileSize > $1.fileSize }
                return $0.score > $1.score
            }
            candidatesByPath[pdfPath] = candidates
        }

        var assigned: [String: URL] = [:]
        var usedFiles = Set<String>()
        let assignmentOrder = pdfPaths.sorted { lhs, rhs in
            let leftTop = candidatesByPath[lhs]?.first?.score ?? Int.min
            let rightTop = candidatesByPath[rhs]?.first?.score ?? Int.min
            if leftTop == rightTop { return lhs < rhs }
            return leftTop > rightTop
        }

        for pdfPath in assignmentOrder {
            guard let candidates = candidatesByPath[pdfPath], !candidates.isEmpty else { continue }
            if let winner = candidates.first(where: { !usedFiles.contains($0.file.path) }) {
                assigned[pdfPath] = winner.file
                usedFiles.insert(winner.file.path)
            }
        }

        return assigned
    }

    private static func files(in directory: URL, withExtension ext: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension.lowercased() == ext.lowercased() else { return nil }
            return url
        }
    }

    private static func bestFileMatch(forPDFPath pdfPath: String, entries: [URL]) -> URL? {
        let baseName = URL(fileURLWithPath: pdfPath).deletingPathExtension().lastPathComponent.lowercased()
        let exact = entries.first { $0.deletingPathExtension().lastPathComponent.lowercased() == baseName }
        if let exact { return exact }

        let partial = entries.filter { $0.deletingPathExtension().lastPathComponent.lowercased().contains(baseName) }
        if partial.count == 1 { return partial[0] }

        let sizedPartial = partial.sorted {
            let a = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let b = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return a > b
        }
        if let first = sizedPartial.first { return first }

        let sizedAll = entries.sorted {
            let a = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let b = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return a > b
        }
        return sizedAll.first
    }

    private static func parseODLBlocks(data: Data) -> [ODLBlock] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var blocks: [ODLBlock] = []
        var seen = Set<ODLBlock>()

        func parseInt(_ any: Any?) -> Int? {
            if let int = any as? Int { return int }
            if let number = any as? NSNumber { return number.intValue }
            if let str = any as? String, let int = Int(str) { return int }
            return nil
        }

        func parseText(_ dict: [String: Any]) -> String? {
            let keys = ["text", "content", "value", "markdown", "md"]
            for key in keys {
                if let val = dict[key] as? String {
                    let t = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                }
            }
            return nil
        }

        func parseType(_ dict: [String: Any]) -> String? {
            let keys = ["type", "label", "kind", "category", "block_type"]
            for key in keys {
                if let val = dict[key] as? String {
                    let t = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t.lowercased() }
                }
            }
            return nil
        }

        func parsePage(_ dict: [String: Any]) -> Int? {
            let keys = ["page", "page_number", "pageNumber", "page_index", "pageIndex"]
            for key in keys {
                if let p = parseInt(dict[key]) { return p }
            }
            if let bbox = dict["bbox"] as? [String: Any], let p = parseInt(bbox["page"]) { return p }
            return nil
        }

        func walk(_ node: Any) {
            if let arr = node as? [Any] {
                for item in arr { walk(item) }
                return
            }
            guard let dict = node as? [String: Any] else { return }

            if let text = parseText(dict), text.count <= 20_000 {
                let block = ODLBlock(page: parsePage(dict), type: parseType(dict), text: text)
                if !seen.contains(block) {
                    seen.insert(block)
                    blocks.append(block)
                }
            }

            for value in dict.values {
                if value is [Any] || value is [String: Any] {
                    walk(value)
                }
            }
        }

        walk(json)
        return blocks
    }

    private static func chunkStructured(blocks: [ODLBlock], maxChunkCharacters: Int) -> [String] {
        guard !blocks.isEmpty else { return [] }
        let normalizedBlocks = blocks.enumerated().sorted { lhs, rhs in
            let lp = lhs.element.page ?? Int.max
            let rp = rhs.element.page ?? Int.max
            if lp == rp { return lhs.offset < rhs.offset }
            return lp < rp
        }
        .map(\.element)

        var chunks: [String] = []
        var current = ""
        var lastPage: Int?

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
            lastPage = nil
        }

        for block in normalizedBlocks {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let page = block.page
            let pagePrefix: String
            if let page, page != lastPage {
                pagePrefix = "[strana \(page)] "
                lastPage = page
            } else {
                pagePrefix = ""
            }

            let marker: String
            if let type = block.type, type.contains("heading") || type == "title" {
                marker = "\n## "
            } else if let type = block.type, type.contains("table") {
                marker = "\n[TABULKA] "
            } else {
                marker = "\n"
            }

            let piece = marker + pagePrefix + text
            if !current.isEmpty && current.count + piece.count > maxChunkCharacters {
                flush()
            }

            if piece.count > maxChunkCharacters {
                let hard = PipelineProfile.chunkText(piece, chunkSize: maxChunkCharacters, chunkOverlap: 0)
                for part in hard where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append(part.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else {
                current += piece
            }
        }

        flush()
        return chunks
    }

    // MARK: - Text layer quality detection

    /// Heuristic: a text layer is usable if it has enough letter/digit characters
    /// relative to its length. Garbage layers tend to have high ratios of replacement
    /// characters, control characters, or repeated symbols.
    private static func hasUsableTextLayer(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 50 else { return false }

        let sample = String(trimmed.prefix(500))
        let letterDigitCount = sample.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        let ratio = Double(letterDigitCount) / Double(sample.count)

        // If less than 40% of characters are letters/digits, likely garbage
        if ratio < 0.4 { return false }

        // Check for high concentration of Unicode replacement characters
        let replacementCount = sample.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
        if replacementCount > sample.count / 10 { return false }

        return true
    }

    // MARK: - OCR (thread-safe, operates on CGImage only)

    private static func ocrImage(_ cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            if let observations = request.results {
                return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
        } catch {
            return "[Chyba OCR: \(error.localizedDescription)]"
        }
        return ""
    }
}
