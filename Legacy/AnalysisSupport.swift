import Foundation

enum AnalysisSupport {
    static let supportedInputExtensions: Set<String> = [
        "c", "cfg", "conf", "cpp", "cs", "css", "csv", "doc", "docx", "env",
        "fnc", "html", "htm", "ini", "java", "js", "json", "md", "odt", "pdf",
        "pck", "pkb", "pks", "pls", "ppt", "pptx", "prc", "properties", "psql",
        "py", "rtf", "sql", "swift", "toml", "trg", "ts", "txt", "vw", "xls",
        "xlsx", "xml", "yaml", "yml"
    ]

    static let plainTextExtensions: Set<String> = [
        "c", "cfg", "conf", "cpp", "cs", "css", "csv", "env", "fnc", "html",
        "htm", "ini", "java", "js", "json", "md", "pck", "pkb", "pks", "pls",
        "prc", "properties", "psql", "py", "sql", "swift", "toml", "trg", "ts",
        "txt", "vw", "xml", "yaml", "yml"
    ]

    static func isGeneratedOutput(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".lm.txt")
            || name.hasPrefix("log--")
            || name.hasPrefix("vystup--")
            || name.hasPrefix("souhrn--")
            || name == ".spice-checkpoint.json"
    }

    static func validateOutput(_ text: String, inputLength: Int) -> [String] {
        var warnings: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            warnings.append("Výstup je prázdný")
            return warnings
        }

        // Only error blocks — all lines start with [Chyba
        let lines = trimmed.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !lines.isEmpty && lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("[Chyba") }) {
            warnings.append("Výstup obsahuje pouze chybové bloky")
        }

        // Size-based checks only when inputLength is known (text path, not vision)
        if inputLength > 200 {
            if trimmed.count < inputLength / 20 {
                warnings.append("Výstup je kratší než 5% vstupu (\(trimmed.count) vs \(inputLength) znaků)")
            }
            if trimmed.count > inputLength * 2 {
                warnings.append("Výstup je delší než 200% vstupu — možná halucinace")
            }
        }

        // Repetition detection: split into 100-char blocks, check duplicates
        if trimmed.count > 500 {
            let blockSize = 100
            var blocks: [String: Int] = [:]
            var idx = trimmed.startIndex
            while idx < trimmed.endIndex {
                let end = trimmed.index(idx, offsetBy: blockSize, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
                let block = String(trimmed[idx..<end])
                blocks[block, default: 0] += 1
                idx = end
            }
            let maxRepeat = blocks.values.max() ?? 0
            if maxRepeat >= 3 {
                warnings.append("Detekován opakující se text (\(maxRepeat)× stejný blok)")
            }
        }

        return warnings
    }

    static func outputFileURL(for sourceFileURL: URL, relativePath: String, outputDirectory: URL) -> URL {
        let relativeDirectory = (relativePath as NSString).deletingLastPathComponent
        let targetDirectory: URL

        if relativeDirectory.isEmpty || relativeDirectory == "." {
            targetDirectory = outputDirectory
        } else {
            targetDirectory = outputDirectory.appendingPathComponent(relativeDirectory, isDirectory: true)
        }

        return targetDirectory.appendingPathComponent(sourceFileURL.lastPathComponent + ".lm.txt")
    }
}
