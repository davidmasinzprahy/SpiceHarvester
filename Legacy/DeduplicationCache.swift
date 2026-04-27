import Foundation

actor DeduplicationCache {
    struct Entry {
        let embedding: [Float]
        let response: String
        let preview: String
    }

    private var entries: [Entry] = []
    let threshold: Double
    private(set) var hitCount: Int = 0
    private(set) var missCount: Int = 0

    init(threshold: Double) {
        self.threshold = threshold
    }

    /// Returns the cached response if any stored embedding has cosine similarity > threshold.
    /// Increments hitCount on match, missCount otherwise.
    func findSimilar(_ embedding: [Float]) -> String? {
        var bestScore = -1.0
        var bestIndex = -1
        for (i, entry) in entries.enumerated() {
            let score = Self.cosineSimilarity(embedding, entry.embedding)
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        if bestIndex >= 0 && bestScore >= threshold {
            hitCount += 1
            return entries[bestIndex].response
        }
        missCount += 1
        return nil
    }

    func store(embedding: [Float], response: String, preview: String) {
        entries.append(Entry(embedding: embedding, response: response, preview: preview))
    }

    func stats() -> (hits: Int, misses: Int, stored: Int) {
        (hitCount, missCount, entries.count)
    }

    // MARK: - Cosine similarity

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1.0 }
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for i in 0..<a.count {
            let av = Double(a[i])
            let bv = Double(b[i])
            dot += av * bv
            normA += av * av
            normB += bv * bv
        }
        let denom = (normA * normB).squareRoot()
        guard denom > 0 else { return -1.0 }
        return dot / denom
    }
}
