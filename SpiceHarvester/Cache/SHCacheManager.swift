import Foundation

actor SHCacheManager {
    private let cacheRoot: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
        self.encoder = SHJSON.encoder()
        self.decoder = SHJSON.decoder()
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    func cacheURL(forHash hash: String) -> URL {
        cacheRoot.appendingPathComponent("\(hash).json")
    }

    func load(hash: String) -> SHCachedDocument? {
        let url = cacheURL(forHash: hash)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SHCachedDocument.self, from: data)
    }

    func save(_ document: SHCachedDocument) {
        let url = cacheURL(forHash: document.fileHash)
        guard let data = try? encoder.encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "json" }.count) ?? 0
    }
}
