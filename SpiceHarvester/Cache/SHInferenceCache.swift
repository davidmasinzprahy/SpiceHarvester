import Foundation
import CryptoKit

/// Content-addressable cache for LLM responses.
///
/// Key = SHA-256 of (user prompt text + sorted document hashes + model id + mode).
/// Value = the raw LLM response string (whatever the model produced – JSON, CSV+TXT,
/// whatever schema the prompt defines).
///
/// Biggest win of this cache: iterating on prompt wording with the same set of PDFs.
/// First run actually hits LM Studio (minutes). Subsequent runs with unchanged
/// prompt + docs + model are instant cache hits (milliseconds), so the user can
/// experiment with the prompt without burning inference time re-running equivalent
/// queries.
///
/// Invalidates automatically when any component of the key changes:
/// - User edits the prompt (even a single character).
/// - User adds / removes / edits PDF files (file hash changes).
/// - User switches inference model.
/// - User switches extraction mode.
actor SHInferenceCache {
    /// Bumped whenever the cache key semantics change. Old entries keyed with a
    /// different schema version will never match, giving us a clean invalidation
    /// point for app upgrades.
    static let schemaVersion = "v3"

    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    struct Envelope: Codable {
        let createdAt: Date
        let model: String
        let modeTag: String
        let response: String
    }

    init(cacheRoot: URL) {
        self.root = cacheRoot.appendingPathComponent("inference")
        self.encoder = SHJSON.encoder(prettyPrinted: false)
        self.decoder = SHJSON.decoder()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Builds a stable key from the semantic inputs of an inference call. Uses
    /// NUL bytes as separators so concatenated fields can't collide.
    ///
    /// The key captures every variable that changes what the model sees:
    /// - `schemaVersion` – invalidates on app upgrade when key semantics evolve.
    /// - `systemPrompt` – bundled extraction system prompt (CZ boilerplate).
    /// - `prompt` – user's task prompt.
    /// - `cleanerVersion` – bumped when `SHTextCleaningService` changes, so a
    ///   cleaning algorithm change invalidates old responses (which were produced
    ///   from differently-cleaned text).
    /// - `documentHashes` – SHA-256 of each source PDF, sorted deterministically.
    /// - `model` – inference model identifier.
    /// - `embeddingModel` – empty string outside SEARCH mode; in SEARCH mode it
    ///   affects which chunks the LLM sees.
    /// - `rerankerModel` – empty outside SEARCH without reranking; when set it
    ///   affects final chunk ordering.
    /// - `modeTag` – fast / search / consolidate.
    static func makeKey(
        systemPrompt: String,
        prompt: String,
        cleanerVersion: String,
        documentHashes: [String],
        model: String,
        embeddingModel: String,
        rerankerModel: String = "",
        modeTag: String
    ) -> String {
        var hasher = SHA256()
        func feed(_ s: String) {
            hasher.update(data: Data(s.utf8))
            hasher.update(data: Data([0x00]))
        }
        feed("schema=\(Self.schemaVersion)")
        feed(systemPrompt)
        feed(prompt)
        feed("cleaner=\(cleanerVersion)")
        // Sorted document hashes, each separated by NUL inside the SHA so
        // ["ab,cd"] and ["ab", "cd"] produce different keys (avoids comma-
        // collision in documentHashes that embed commas – theoretical, but free).
        let sorted = documentHashes.sorted()
        for h in sorted {
            hasher.update(data: Data(h.utf8))
            hasher.update(data: Data([0x01])) // inner separator
        }
        hasher.update(data: Data([0x00]))
        feed("model=\(model)")
        feed("embModel=\(embeddingModel)")
        feed("rerankerModel=\(rerankerModel)")
        feed("mode=\(modeTag)")
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func load(key: String) -> String? {
        let url = root.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return nil
        }
        return envelope.response
    }

    func save(key: String, response: String, model: String, modeTag: String) {
        let url = root.appendingPathComponent("\(key).json")
        let envelope = Envelope(createdAt: Date(), model: model, modeTag: modeTag, response: response)
        guard let data = try? encoder.encode(envelope) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .count) ?? 0
    }
}

actor SHEmbeddingCache {
    static let schemaVersion = "v2"

    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    struct Envelope: Codable {
        let createdAt: Date
        let model: String
        let embedding: [Double]
    }

    init(cacheRoot: URL) {
        self.root = cacheRoot.appendingPathComponent("embeddings")
        self.encoder = SHJSON.encoder(prettyPrinted: false)
        self.decoder = SHJSON.decoder()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func makeKey(server: SHServerConfig, model: String, input: String) -> String {
        var hasher = SHA256()
        func feed(_ s: String) {
            hasher.update(data: Data(s.utf8))
            hasher.update(data: Data([0x00]))
        }
        feed("schema=\(Self.schemaVersion)")
        feed("server=\(server.normalizedBaseURL?.absoluteString ?? server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))")
        feed("model=\(model)")
        feed(input)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func load(key: String) -> [Double]? {
        let url = root.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return nil
        }
        return envelope.embedding
    }

    func save(key: String, embedding: [Double], model: String) {
        let url = root.appendingPathComponent("\(key).json")
        let envelope = Envelope(createdAt: Date(), model: model, embedding: embedding)
        guard let data = try? encoder.encode(envelope) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
