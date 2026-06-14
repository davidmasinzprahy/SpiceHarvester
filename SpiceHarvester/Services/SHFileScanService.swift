import Foundation
import CryptoKit

struct SHFileScanService {
    static let supportedDocumentExtensions: Set<String> = [
        "pdf",
        "txt",
        "text",
        "md",
        "markdown",
        "csv",
        "tsv",
        "json",
        // office (pandoc, Fáze 1)
        "docx",
        "odt",
        "rtf",
        "html",
        "htm",
        "epub",
        // tabulky (csvkit / in2csv, Fáze 2)
        "xlsx",
        "xls"
    ]

    func recursiveDocuments(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [URL] = []
        for case let url as URL in enumerator {
            guard Self.supportedDocumentExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == false {
                continue
            }
            items.append(url)
        }
        return items.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func recursivePDFs(in root: URL) -> [URL] {
        recursiveDocuments(in: root).filter { $0.pathExtension.lowercased() == "pdf" }
    }

    func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1 MiB
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
