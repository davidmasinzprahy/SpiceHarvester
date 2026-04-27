import Foundation

struct PreprocessingProfile: Identifiable, Equatable {
    let id: String
    let displayName: String
    let normalizeWhitespace: Bool
    let deduplicatePageHeaders: Bool
    let smartChunking: Bool
    let useVision: Bool
    let useOpenDataLoader: Bool
    let useEmbeddingDedup: Bool
    let embeddingSimilarityThreshold: Double
    let ocrResolutionWidth: CGFloat
    let visionResolutionWidth: CGFloat
    let visionPageBatchSize: Int
    let tokenRatio: Double
    let defaultPrompt: String
    let defaultContinuationPrompt: String

    static let profiles: [PreprocessingProfile] = [
        PreprocessingProfile(
            id: "medical",
            displayName: "Medicínské zprávy",
            normalizeWhitespace: true,
            deduplicatePageHeaders: true,
            smartChunking: true,
            useVision: false,
            useOpenDataLoader: true,
            useEmbeddingDedup: true,
            embeddingSimilarityThreshold: 0.93,
            ocrResolutionWidth: 2400,
            visionResolutionWidth: 1200,
            visionPageBatchSize: 3,
            tokenRatio: 3.2,
            defaultPrompt: "Z textu nemocničního dokumentu extrahuj pouze klinicky relevantní obsah.\nVstup je předzpracován — záhlaví a zápatí stránek jsou odstraněna.\nODSTRAŇ: identifikaci nemocnice, IČO, adresu, telefon, datum tisku, podpisy, razítka.\nZACHOVEJ: veškerý klinický obsah v původním znění.\nFORMÁT: prostý text. Zachovej původní názvy sekcí. Sekce odděl jedním prázdným řádkem. Spoj věty roztržené zalomením řádku. Na první řádek uveď PACIENT: [jméno].\nNic nepřidávej, nevysvětluj, nekomentuj.",
            defaultContinuationPrompt: "Pokračuj v extrakci klinického obsahu z další části téhož dokumentu.\nNezačínej hlavičkou PACIENT. Pokračuj přímo obsahem od místa kde text začíná.\nZachovej původní názvy sekcí. Nic nepřidávej, nevysvětluj, nekomentuj."
        ),
        PreprocessingProfile(
            id: "legal",
            displayName: "Právní dokumenty",
            normalizeWhitespace: true,
            deduplicatePageHeaders: true,
            smartChunking: true,
            useVision: false,
            useOpenDataLoader: true,
            useEmbeddingDedup: true,
            embeddingSimilarityThreshold: 0.93,
            ocrResolutionWidth: 2400,
            visionResolutionWidth: 1200,
            visionPageBatchSize: 3,
            tokenRatio: 3.5,
            defaultPrompt: "Extrahuj hlavní obsah právního dokumentu.\nODSTRAŇ: hlavičky stran, čísla stran, podpisové bloky, razítka.\nZACHOVEJ: veškeré smluvní podmínky, články, odstavce v původním znění.\nFORMÁT: prostý text se zachovanou strukturou článků a odstavců.",
            defaultContinuationPrompt: "Pokračuj v extrakci právního textu z další části téhož dokumentu. Nezačínej od začátku."
        ),
        PreprocessingProfile(
            id: "academic",
            displayName: "Akademické texty",
            normalizeWhitespace: true,
            deduplicatePageHeaders: true,
            smartChunking: true,
            useVision: false,
            useOpenDataLoader: true,
            useEmbeddingDedup: false,
            embeddingSimilarityThreshold: 0.95,
            ocrResolutionWidth: 2000,
            visionResolutionWidth: 1200,
            visionPageBatchSize: 3,
            tokenRatio: 3.8,
            defaultPrompt: "Shrň hlavní poznatky akademického textu.\nZACHOVEJ: abstrakt, metodologii, výsledky, závěry.\nFORMÁT: prostý strukturovaný text.",
            defaultContinuationPrompt: "Pokračuj v analýze další části téhož textu."
        ),
        PreprocessingProfile(
            id: "word",
            displayName: "Word dokumenty",
            normalizeWhitespace: true,
            deduplicatePageHeaders: false,
            smartChunking: true,
            useVision: false,
            useOpenDataLoader: false,
            useEmbeddingDedup: false,
            embeddingSimilarityThreshold: 0.95,
            ocrResolutionWidth: 1600,
            visionResolutionWidth: 1200,
            visionPageBatchSize: 3,
            tokenRatio: 3.8,
            defaultPrompt: "",
            defaultContinuationPrompt: ""
        ),
        PreprocessingProfile(
            id: "scanned",
            displayName: "Skenované dokumenty (vision)",
            normalizeWhitespace: true,
            deduplicatePageHeaders: true,
            smartChunking: true,
            useVision: true,
            useOpenDataLoader: true,
            useEmbeddingDedup: false,
            embeddingSimilarityThreshold: 0.95,
            ocrResolutionWidth: 3000,
            visionResolutionWidth: 1400,
            visionPageBatchSize: 2,
            tokenRatio: 3.2,
            defaultPrompt: "Přepiš obsah skenovaného dokumentu do čistého textu.\nZachovej strukturu a formátování originálu.\nOprav zjevné chyby z OCR/skenu.\nFORMÁT: prostý text.",
            defaultContinuationPrompt: "Pokračuj v přepisu další stránky téhož dokumentu."
        ),
        PreprocessingProfile(
            id: "receipts",
            displayName: "Účtenky a faktury (vision)",
            normalizeWhitespace: true,
            deduplicatePageHeaders: false,
            smartChunking: false,
            useVision: true,
            useOpenDataLoader: true,
            useEmbeddingDedup: true,
            embeddingSimilarityThreshold: 0.95,
            ocrResolutionWidth: 3000,
            visionResolutionWidth: 1600,
            visionPageBatchSize: 3,
            tokenRatio: 3.0,
            defaultPrompt: "Z obrázku účtenky/faktury extrahuj:\n- Dodavatel (název, IČO, DIČ)\n- Datum vystavení\n- Číslo dokladu\n- Položky (název, množství, cena za kus, celkem)\n- Celková částka, DPH\n- Způsob úhrady\nFORMÁT: prostý text, jedna položka na řádek.",
            defaultContinuationPrompt: "Pokračuj v extrakci dat z dalšího obrázku účtenky/faktury. Neformátuj znovu hlavičku."
        ),
        PreprocessingProfile(
            id: "tabular",
            displayName: "Tabulková data (CSV)",
            normalizeWhitespace: false,
            deduplicatePageHeaders: false,
            smartChunking: false,
            useVision: false,
            useOpenDataLoader: false,
            useEmbeddingDedup: false,
            embeddingSimilarityThreshold: 0.95,
            ocrResolutionWidth: 1600,
            visionResolutionWidth: 1200,
            visionPageBatchSize: 3,
            tokenRatio: 4.0,
            defaultPrompt: "",
            defaultContinuationPrompt: ""
        ),
        PreprocessingProfile(
            id: "code",
            displayName: "Zdrojový kód",
            normalizeWhitespace: false,
            deduplicatePageHeaders: false,
            smartChunking: false,
            useVision: false,
            useOpenDataLoader: false,
            useEmbeddingDedup: false,
            embeddingSimilarityThreshold: 0.95,
            ocrResolutionWidth: 1600,
            visionResolutionWidth: 1200,
            visionPageBatchSize: 3,
            tokenRatio: 3.5,
            defaultPrompt: "",
            defaultContinuationPrompt: ""
        ),
        PreprocessingProfile(
            id: "default",
            displayName: "Obecný text",
            normalizeWhitespace: true,
            deduplicatePageHeaders: false,
            smartChunking: true,
            useVision: false,
            useOpenDataLoader: false,
            useEmbeddingDedup: false,
            embeddingSimilarityThreshold: 0.95,
            ocrResolutionWidth: 1600,
            visionResolutionWidth: 1200,
            visionPageBatchSize: 3,
            tokenRatio: 4.0,
            defaultPrompt: "",
            defaultContinuationPrompt: ""
        ),
    ]

    static let defaultProfile = profiles.first { $0.id == "default" }!

    static func allProfiles() -> [PreprocessingProfile] {
        let userProfiles = UserProfileManager.loadUserProfiles()
        let userIDs = Set(userProfiles.map(\.id))
        // User profiles override built-in profiles with same ID
        return profiles.filter { !userIDs.contains($0.id) } + userProfiles
    }

    static func profile(for id: String) -> PreprocessingProfile {
        if let builtin = profiles.first(where: { $0.id == id }) { return builtin }
        if let user = UserProfileManager.loadUserProfiles().first(where: { $0.id == id }) { return user }
        return defaultProfile
    }

    static let codeExtensions: Set<String> = [
        "c", "cfg", "conf", "cpp", "cs", "css", "env", "fnc", "html", "htm",
        "ini", "java", "js", "json", "pck", "pkb", "pks", "pls", "prc",
        "properties", "psql", "py", "sql", "swift", "toml", "trg", "ts",
        "vw", "xml", "yaml", "yml"
    ]

    static func recommended(forExtension ext: String) -> PreprocessingProfile {
        let lower = ext.lowercased()
        if codeExtensions.contains(lower) { return profile(for: "code") }
        if lower == "csv" { return profile(for: "tabular") }
        if ["docx", "doc", "odt", "rtf"].contains(lower) { return profile(for: "word") }
        if lower == "md" || lower == "txt" { return defaultProfile }
        if lower == "pdf" { return defaultProfile }
        return defaultProfile
    }

    // MARK: - Preprocessing pipeline

    static func preprocess(_ text: String, profile: PreprocessingProfile) -> String {
        var result = text

        // Unicode NFC normalization — unifies diacritics (č as one codepoint vs c + combining háček)
        // Only for text profiles; code profiles must preserve raw bytes
        if profile.normalizeWhitespace {
            result = result.precomposedStringWithCanonicalMapping
        }

        if profile.deduplicatePageHeaders {
            result = deduplicateHeaders(result)
        } else {
            result = result.replacingOccurrences(of: "[[PAGE_BREAK]]", with: "\n\n")
        }

        if profile.normalizeWhitespace {
            result = normalizeWhitespace(result)
        }

        return result
    }

    static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{FEFF}", with: "")  // BOM removal
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deduplicateHeaders(_ text: String) -> String {
        let pages = text.components(separatedBy: "[[PAGE_BREAK]]")
        guard pages.count >= 2 else {
            return text.replacingOccurrences(of: "[[PAGE_BREAK]]", with: "\n\n")
        }

        let trimmedPages = pages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let lineArrays = trimmedPages.map { $0.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) } }

        var headerLines: Set<String> = []
        var footerLines: Set<String> = []

        // Find lines repeated at the start of most pages
        let threshold = max(2, lineArrays.count / 2)
        let maxProbe = 3

        for lineIdx in 0..<maxProbe {
            var lineCounts: [String: Int] = [:]
            for pageLines in lineArrays where pageLines.count > lineIdx {
                let line = pageLines[lineIdx]
                if !line.isEmpty {
                    lineCounts[line, default: 0] += 1
                }
            }
            for (line, count) in lineCounts where count >= threshold {
                headerLines.insert(line)
            }
        }

        // Find lines repeated at the end of most pages
        for offset in 0..<maxProbe {
            var lineCounts: [String: Int] = [:]
            for pageLines in lineArrays {
                let idx = pageLines.count - 1 - offset
                guard idx >= 0 else { continue }
                let line = pageLines[idx]
                if !line.isEmpty {
                    lineCounts[line, default: 0] += 1
                }
            }
            for (line, count) in lineCounts where count >= threshold {
                footerLines.insert(line)
            }
        }

        if headerLines.isEmpty && footerLines.isEmpty {
            return text.replacingOccurrences(of: "[[PAGE_BREAK]]", with: "\n\n")
        }

        var cleanedPages: [String] = []
        for (pageIndex, pageText) in trimmedPages.enumerated() {
            var lines = pageText.components(separatedBy: "\n")

            if pageIndex > 0 {
                // Remove header lines from top
                while let first = lines.first, headerLines.contains(first.trimmingCharacters(in: .whitespaces)) {
                    lines.removeFirst()
                }
            }

            // Remove footer lines from bottom
            while let last = lines.last, footerLines.contains(last.trimmingCharacters(in: .whitespaces)) {
                lines.removeLast()
            }

            let cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                cleanedPages.append(cleaned)
            }
        }

        return cleanedPages.joined(separator: "\n\n")
    }

    // MARK: - Smart chunking

    static func chunkSmart(_ text: String, chunkSize: Int, chunkOverlap: Int) -> [String] {
        guard chunkSize > 0, !text.isEmpty else { return text.isEmpty ? [] : [text] }

        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !paragraphs.isEmpty else { return text.isEmpty ? [] : [text] }

        var chunks: [String] = []
        var currentChunk = ""

        for para in paragraphs {
            let addition = currentChunk.isEmpty ? para : "\n\n" + para

            if !currentChunk.isEmpty && currentChunk.count + addition.count > chunkSize {
                chunks.append(currentChunk)
                // Overlap: carry suffix of previous chunk, aligned to word boundary
                let overlap = min(chunkOverlap, currentChunk.count)
                var overlapText = overlap > 0 ? String(currentChunk.suffix(overlap)) : ""
                if let spaceIdx = overlapText.firstIndex(of: " ") {
                    overlapText = String(overlapText[spaceIdx...]).trimmingCharacters(in: .whitespaces)
                }
                currentChunk = overlapText + (overlapText.isEmpty ? "" : "\n\n") + para
            } else {
                currentChunk += addition
            }
        }

        if !currentChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(currentChunk)
        }

        // Fallback: if a single paragraph exceeds chunkSize, split it with sliding window
        var finalChunks: [String] = []
        for chunk in chunks {
            if chunk.count > chunkSize * 2 {
                finalChunks.append(contentsOf: PipelineProfile.chunkText(chunk, chunkSize: chunkSize, chunkOverlap: chunkOverlap))
            } else {
                finalChunks.append(chunk)
            }
        }

        return finalChunks
    }
}
