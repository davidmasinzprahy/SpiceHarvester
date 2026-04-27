import Foundation

struct EmbeddingService: EmbeddingServicing {
    let analysisController: AnalysisRunController
    let lmStudioURL: String
    let lmStudioAPIToken: String
    let timeout: TimeInterval
    let onStatus: @Sendable (String) -> Void

    private static let retryableStatusCodes: Set<Int> = [429, 503]
    private static let maxRetries = 2
    private static let baseRetryDelay: TimeInterval = 1.5

    static func normalizeEmbeddingsURL(_ rawURL: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }

        let path = url.path.lowercased()
        if path.hasSuffix("/v1/embeddings") || path.hasSuffix("/embeddings") {
            return url
        }

        // Build from base (strip any trailing /v1/chat/completions or /chat/completions)
        var base = trimmed
        while base.hasSuffix("/") { base = String(base.dropLast()) }

        if path.hasSuffix("/v1/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
            return URL(string: "\(base)/embeddings")
        }
        if path.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
            return URL(string: "\(base)/v1/embeddings")
        }
        if path.hasSuffix("/v1") {
            return URL(string: "\(base)/embeddings")
        }
        return URL(string: "\(base)/v1/embeddings")
    }

    func embed(texts: [String], modelName: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard !modelName.isEmpty else {
            throw AnalysisError.invalidModelName
        }
        guard let url = Self.normalizeEmbeddingsURL(lmStudioURL) else {
            throw AnalysisError.invalidURL
        }

        let payload: [String: Any] = [
            "model": modelName,
            "input": texts
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw AnalysisError.jsonSerializationFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedToken = lmStudioAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = min(timeout, 60)
        request.httpBody = jsonData

        var lastError: AnalysisError?
        for attempt in 0...Self.maxRetries {
            try Task.checkCancellation()

            let taskID = UUID()
            do {
                let (data, response): (Data, URLResponse) = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let task = URLSession.shared.dataTask(with: request) { data, response, error in
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            guard let data, let response else {
                                continuation.resume(
                                    throwing: NSError(
                                        domain: "EmbeddingService",
                                        code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Prázdná odpověď serveru"]
                                    )
                                )
                                return
                            }
                            continuation.resume(returning: (data, response))
                        }
                        analysisController.register(task: task, id: taskID)
                        task.resume()
                    }
                } onCancel: {
                    analysisController.cancelTask(id: taskID)
                }
                analysisController.unregisterTask(id: taskID)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AnalysisError.connectionFailed("Neplatná odpověď serveru (embeddings)")
                }

                let statusCode = httpResponse.statusCode
                if Self.retryableStatusCodes.contains(statusCode) && attempt < Self.maxRetries {
                    let delay = Self.baseRetryDelay * pow(2.0, Double(attempt))
                    onStatus("Embedding server přetížen (\(statusCode)), čekám \(Int(delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    lastError = .connectionFailed("HTTP \(statusCode)")
                    continue
                }

                guard (200...299).contains(statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw AnalysisError.connectionFailed("HTTP \(statusCode): \(body)")
                }

                return try Self.parseEmbeddingsResponse(data: data, expectedCount: texts.count)
            } catch is CancellationError {
                analysisController.unregisterTask(id: taskID)
                throw AnalysisError.cancelled
            } catch let error as AnalysisError {
                analysisController.unregisterTask(id: taskID)
                throw error
            } catch {
                analysisController.unregisterTask(id: taskID)
                if attempt < Self.maxRetries {
                    let delay = Self.baseRetryDelay * pow(2.0, Double(attempt))
                    lastError = .connectionFailed(error.localizedDescription)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw AnalysisError.connectionFailed(error.localizedDescription)
            }
        }
        throw lastError ?? AnalysisError.connectionFailed("Embedding retry limit exceeded")
    }

    static func parseEmbeddingsResponse(data: Data, expectedCount: Int) throws -> [[Float]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw AnalysisError.connectionFailed("Neplatná JSON odpověď z /v1/embeddings")
        }

        let indexedItems: [(offset: Int, index: Int?, item: [String: Any])] = items.enumerated().map { offset, item in
            let index = (item["index"] as? Int) ?? (item["index"] as? NSNumber)?.intValue
            return (offset: offset, index: index, item: item)
        }

        let allHaveIndex = indexedItems.allSatisfy { $0.index != nil }
        let orderedItems: [[String: Any]]
        if allHaveIndex {
            orderedItems = indexedItems.sorted { lhs, rhs in
                let li = lhs.index ?? Int.max
                let ri = rhs.index ?? Int.max
                if li == ri { return lhs.offset < rhs.offset }
                return li < ri
            }.map(\.item)
        } else {
            orderedItems = indexedItems.sorted { $0.offset < $1.offset }.map(\.item)
        }

        var result: [[Float]] = []
        result.reserveCapacity(orderedItems.count)
        for item in orderedItems {
            if let doubles = item["embedding"] as? [Double] {
                result.append(doubles.map { Float($0) })
            } else if let numbers = item["embedding"] as? [NSNumber] {
                result.append(numbers.map { $0.floatValue })
            } else {
                throw AnalysisError.connectionFailed("Embedding položka neobsahuje pole 'embedding'")
            }
        }

        if result.count != expectedCount {
            throw AnalysisError.connectionFailed("Server vrátil \(result.count) embeddingů, očekáváno \(expectedCount)")
        }

        return result
    }
}
