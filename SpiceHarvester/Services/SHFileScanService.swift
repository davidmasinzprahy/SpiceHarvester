import Foundation
import CryptoKit

struct SHFileScanService {
    func recursivePDFs(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "pdf" {
                items.append(url)
            }
        }
        return items.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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
