import Foundation

struct PipelineProfile: Equatable {
    let id: String
    let displayName: String
    let modelMatchers: [String]
    let chunkSize: Int
    let chunkOverlap: Int
    let embeddingModel: String
    let vectorSize: Int
    let qdrantCollectionName: String

    static let profiles: [PipelineProfile] = [
        PipelineProfile(
            id: "gpt-oss-20b",
            displayName: "GPT-OSS 20B RAG",
            modelMatchers: ["gpt-oss-20b", "gpt oss 20b"],
            chunkSize: 1200,
            chunkOverlap: 150,
            embeddingModel: "bge-m3",
            vectorSize: 1024,
            qdrantCollectionName: "rag-bge-m3-c1200-o150-v1024"
        ),
        PipelineProfile(
            id: "qwen3-coder",
            displayName: "Qwen3 Coder RAG",
            modelMatchers: ["qwen3-coder", "qwen coder", "qwen3"],
            chunkSize: 1000,
            chunkOverlap: 120,
            embeddingModel: "bge-m3",
            vectorSize: 1024,
            qdrantCollectionName: "rag-bge-m3-c1000-o120-v1024"
        ),
        PipelineProfile(
            id: "llama",
            displayName: "Llama RAG",
            modelMatchers: ["llama", "meta-llama"],
            chunkSize: 900,
            chunkOverlap: 120,
            embeddingModel: "bge-m3",
            vectorSize: 1024,
            qdrantCollectionName: "rag-bge-m3-c900-o120-v1024"
        ),
        PipelineProfile(
            id: "default",
            displayName: "Default RAG",
            modelMatchers: [],
            chunkSize: 1000,
            chunkOverlap: 120,
            embeddingModel: "bge-m3",
            vectorSize: 1024,
            qdrantCollectionName: "rag-bge-m3-c1000-o120-v1024"
        )
    ]

    static func recommended(for modelID: String) -> PipelineProfile {
        let normalizedModelID = modelID.lowercased()

        return profiles.first(where: { profile in
            profile.modelMatchers.contains(where: { normalizedModelID.contains($0) })
        }) ?? profiles.last!
    }

    static func chunkText(_ text: String, chunkSize: Int, chunkOverlap: Int) -> [String] {
        guard chunkSize > 0, !text.isEmpty else { return text.isEmpty ? [] : [text] }

        let overlap = max(0, min(chunkOverlap, chunkSize - 1))
        let step = max(chunkSize - overlap, 1)
        var chunks: [String] = []
        var startIndex = text.startIndex

        while startIndex < text.endIndex {
            let endIndex = text.index(startIndex, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[startIndex..<endIndex]))

            if endIndex == text.endIndex {
                break
            }

            startIndex = text.index(startIndex, offsetBy: step, limitedBy: text.endIndex) ?? text.endIndex
        }

        return chunks
    }
}

struct QdrantPipelineManifest: Equatable {
    let profileID: String?
    let collectionName: String
    let chunkSize: Int
    let chunkOverlap: Int
    let embeddingModel: String
    let vectorSize: Int
}

struct QdrantCollectionValidationResult {
    let vectorSize: Int
    let collectionName: String
    let manifest: QdrantPipelineManifest
}

enum QdrantValidationError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case missingVectorSize
    case missingPipelineManifest
    case invalidPipelineManifest
    case collectionCreationFailed(String)
    case manifestUpsertFailed(String)
    case httpError(String)
    case collectionMismatch(expected: String, actual: String)
    case vectorSizeMismatch(expected: Int, actual: Int)
    case chunkSizeMismatch(expected: Int, actual: Int)
    case chunkOverlapMismatch(expected: Int, actual: Int)
    case embeddingModelMismatch(expected: String, actual: String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Chyba: Qdrant URL není validní."
        case .invalidResponse:
            return "Chyba: Qdrant vrátil neplatnou odpověď."
        case .missingVectorSize:
            return "Chyba: z Qdrant kolekce se nepodařilo zjistit velikost vektoru."
        case .missingPipelineManifest:
            return "Chyba: v Qdrant kolekci chybí manifest konfigurace. Očekáván je payload s record_type = pipeline_profile."
        case .invalidPipelineManifest:
            return "Chyba: manifest konfigurace v Qdrantu je neplatný nebo neúplný."
        case .collectionCreationFailed(let body):
            return "Chyba: nepodařilo se vytvořit Qdrant kolekci. \(body)"
        case .manifestUpsertFailed(let body):
            return "Chyba: nepodařilo se zapsat manifest konfigurace do Qdrantu. \(body)"
        case .httpError(let body):
            return "Chyba HTTP z Qdrantu: \(body)"
        case .collectionMismatch(let expected, let actual):
            return "Chyba: Qdrant kolekce neodpovídá konfiguraci. Očekávána: \(expected), nastaveno: \(actual)."
        case .vectorSizeMismatch(let expected, let actual):
            return "Chyba: velikost vektoru v Qdrantu nesedí. Očekáváno \(expected), nalezeno \(actual)."
        case .chunkSizeMismatch(let expected, let actual):
            return "Chyba: velikost bloku v Qdrantu nesedí. Očekáváno \(expected), nalezeno \(actual)."
        case .chunkOverlapMismatch(let expected, let actual):
            return "Chyba: překryv bloků v Qdrantu nesedí. Očekáváno \(expected), nalezeno \(actual)."
        case .embeddingModelMismatch(let expected, let actual):
            return "Chyba: embedovací model v Qdrantu nesedí. Očekáván \(expected), nalezen \(actual)."
        case .requestFailed(let message):
            return "Chyba spojení s Qdrantem: \(message)"
        }
    }
}

enum QdrantValidator {
    static let manifestPointID = 0

    static func prepareCollection(
        baseURL: String,
        collectionName: String,
        apiKey: String,
        expectedProfile: PipelineProfile,
        timeout: TimeInterval
    ) async -> Result<Void, QdrantValidationError> {
        switch await fetchCollectionInfo(
            baseURL: baseURL,
            collectionName: collectionName,
            apiKey: apiKey,
            timeout: timeout
        ) {
        case .success:
            break
        case .failure(.httpError(let body)) where body.contains("doesn't exist") || body.contains("Not found"):
            switch await createCollection(
                baseURL: baseURL,
                collectionName: collectionName,
                apiKey: apiKey,
                expectedProfile: expectedProfile,
                timeout: timeout
            ) {
            case .success:
                break
            case .failure(let error):
                return .failure(error)
            }
        case .failure(let error):
            return .failure(error)
        }

        return await upsertPipelineManifest(
            baseURL: baseURL,
            collectionName: collectionName,
            apiKey: apiKey,
            expectedProfile: expectedProfile,
            timeout: timeout
        )
    }

    static func validateCollection(
        baseURL: String,
        collectionName: String,
        apiKey: String,
        expectedProfile: PipelineProfile,
        timeout: TimeInterval
    ) async -> Result<QdrantCollectionValidationResult, QdrantValidationError> {
        guard collectionName == expectedProfile.qdrantCollectionName else {
            return .failure(.collectionMismatch(expected: expectedProfile.qdrantCollectionName, actual: collectionName))
        }

        switch await fetchCollectionInfo(baseURL: baseURL, collectionName: collectionName, apiKey: apiKey, timeout: timeout) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            guard let vectorSize = parseVectorSize(from: data) else {
                return .failure(.missingVectorSize)
            }
            guard vectorSize == expectedProfile.vectorSize else {
                return .failure(.vectorSizeMismatch(expected: expectedProfile.vectorSize, actual: vectorSize))
            }
            switch await fetchPipelineManifest(
                baseURL: baseURL,
                collectionName: collectionName,
                apiKey: apiKey,
                timeout: timeout
            ) {
            case .failure(let error):
                return .failure(error)
            case .success(let manifest):
                guard manifest.collectionName == expectedProfile.qdrantCollectionName else {
                    return .failure(.collectionMismatch(expected: expectedProfile.qdrantCollectionName, actual: manifest.collectionName))
                }
                guard manifest.chunkSize == expectedProfile.chunkSize else {
                    return .failure(.chunkSizeMismatch(expected: expectedProfile.chunkSize, actual: manifest.chunkSize))
                }
                guard manifest.chunkOverlap == expectedProfile.chunkOverlap else {
                    return .failure(.chunkOverlapMismatch(expected: expectedProfile.chunkOverlap, actual: manifest.chunkOverlap))
                }
                guard manifest.embeddingModel == expectedProfile.embeddingModel else {
                    return .failure(.embeddingModelMismatch(expected: expectedProfile.embeddingModel, actual: manifest.embeddingModel))
                }
                guard manifest.vectorSize == expectedProfile.vectorSize else {
                    return .failure(.vectorSizeMismatch(expected: expectedProfile.vectorSize, actual: manifest.vectorSize))
                }
                return .success(
                    QdrantCollectionValidationResult(
                        vectorSize: vectorSize,
                        collectionName: collectionName,
                        manifest: manifest
                    )
                )
            }
        }
    }

    static func fetchCollectionInfo(
        baseURL: String,
        collectionName: String,
        apiKey: String,
        timeout: TimeInterval
    ) async -> Result<Data, QdrantValidationError> {
        guard let collectionURL = collectionInfoURL(baseURL: baseURL, collectionName: collectionName) else {
            return .failure(.invalidBaseURL)
        }

        var request = URLRequest(url: collectionURL)
        request.httpMethod = "GET"
        request.timeoutInterval = min(timeout, 30)
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "bez těla odpovědi"
                return .failure(.httpError(body))
            }
            return .success(data)
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    static func collectionInfoURL(baseURL: String, collectionName: String) -> URL? {
        let sanitizedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: "\(sanitizedBaseURL)/collections/\(collectionName)")
    }

    static func parseVectorSize(from data: Data?) -> Int? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let config = result["config"] as? [String: Any],
              let params = config["params"] as? [String: Any],
              let vectors = params["vectors"] else {
            return nil
        }

        if let singleVectorConfig = vectors as? [String: Any],
           let size = singleVectorConfig["size"] as? Int {
            return size
        }

        if let namedVectors = vectors as? [String: Any] {
            for value in namedVectors.values {
                if let vectorConfig = value as? [String: Any],
                   let size = vectorConfig["size"] as? Int {
                    return size
                }
            }
        }

        return nil
    }

    static func fetchPipelineManifest(
        baseURL: String,
        collectionName: String,
        apiKey: String,
        timeout: TimeInterval
    ) async -> Result<QdrantPipelineManifest, QdrantValidationError> {
        guard let scrollURL = collectionScrollURL(baseURL: baseURL, collectionName: collectionName) else {
            return .failure(.invalidBaseURL)
        }

        let payload: [String: Any] = [
            "limit": 1,
            "with_payload": true,
            "with_vector": false,
            "filter": [
                "must": [
                    [
                        "key": "record_type",
                        "match": [
                            "value": "pipeline_profile"
                        ]
                    ]
                ]
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure(.invalidResponse)
        }

        var request = URLRequest(url: scrollURL)
        request.httpMethod = "POST"
        request.timeoutInterval = min(timeout, 30)
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }

            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "bez těla odpovědi"
                return .failure(.httpError(body))
            }

            guard let manifest = parsePipelineManifest(from: data) else {
                return .failure(.missingPipelineManifest)
            }

            return .success(manifest)
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    static func collectionScrollURL(baseURL: String, collectionName: String) -> URL? {
        let sanitizedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: "\(sanitizedBaseURL)/collections/\(collectionName)/points/scroll")
    }

    static func parsePipelineManifest(from data: Data?) -> QdrantPipelineManifest? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let points = result["points"] as? [[String: Any]],
              let firstPoint = points.first,
              let payload = firstPoint["payload"] as? [String: Any] else {
            return nil
        }

        guard let collectionName = payload["collection_name"] as? String,
              let chunkSize = payload["chunk_size"] as? Int,
              let chunkOverlap = payload["chunk_overlap"] as? Int,
              let embeddingModel = payload["embedding_model"] as? String,
              let vectorSize = payload["vector_size"] as? Int else {
            return nil
        }

        return QdrantPipelineManifest(
            profileID: payload["profile_id"] as? String,
            collectionName: collectionName,
            chunkSize: chunkSize,
            chunkOverlap: chunkOverlap,
            embeddingModel: embeddingModel,
            vectorSize: vectorSize
        )
    }

    static func createCollection(
        baseURL: String,
        collectionName: String,
        apiKey: String,
        expectedProfile: PipelineProfile,
        timeout: TimeInterval
    ) async -> Result<Void, QdrantValidationError> {
        guard let collectionURL = collectionInfoURL(baseURL: baseURL, collectionName: collectionName) else {
            return .failure(.invalidBaseURL)
        }

        let payload: [String: Any] = [
            "vectors": [
                "size": expectedProfile.vectorSize,
                "distance": "Cosine"
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure(.invalidResponse)
        }

        var request = URLRequest(url: collectionURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = min(timeout, 30)
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "bez těla odpovědi"
                return .failure(.collectionCreationFailed(body))
            }
            return .success(())
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    static func upsertPipelineManifest(
        baseURL: String,
        collectionName: String,
        apiKey: String,
        expectedProfile: PipelineProfile,
        timeout: TimeInterval
    ) async -> Result<Void, QdrantValidationError> {
        guard let pointsURL = pointsUpsertURL(baseURL: baseURL, collectionName: collectionName) else {
            return .failure(.invalidBaseURL)
        }

        let zeroVector = Array(repeating: 0.0, count: expectedProfile.vectorSize)
        let payload: [String: Any] = [
            "points": [
                [
                    "id": manifestPointID,
                    "vector": zeroVector,
                    "payload": [
                        "record_type": "pipeline_profile",
                        "profile_id": expectedProfile.id,
                        "collection_name": expectedProfile.qdrantCollectionName,
                        "chunk_size": expectedProfile.chunkSize,
                        "chunk_overlap": expectedProfile.chunkOverlap,
                        "embedding_model": expectedProfile.embeddingModel,
                        "vector_size": expectedProfile.vectorSize
                    ]
                ]
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure(.invalidResponse)
        }

        var request = URLRequest(url: pointsURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = min(timeout, 30)
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "bez těla odpovědi"
                return .failure(.manifestUpsertFailed(body))
            }
            return .success(())
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    static func pointsUpsertURL(baseURL: String, collectionName: String) -> URL? {
        let sanitizedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: "\(sanitizedBaseURL)/collections/\(collectionName)/points")
    }

    // MARK: - Retry helper (Phase E)

    /// Retries an async operation up to `maxAttempts` times with exponential backoff.
    /// Only retries `.requestFailed` errors; all other errors propagate immediately.
    static func withRetry<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        operation: () async -> Result<T, QdrantValidationError>
    ) async -> Result<T, QdrantValidationError> {
        var lastError: QdrantValidationError?
        for attempt in 0..<maxAttempts {
            let result = await operation()
            switch result {
            case .success:
                return result
            case .failure(let error):
                if case .requestFailed = error {
                    lastError = error
                    if attempt < maxAttempts - 1 {
                        let delay = initialDelay * pow(2.0, Double(attempt))
                        try? await Task.sleep(for: .seconds(delay))
                    }
                } else {
                    return result
                }
            }
        }
        return .failure(lastError ?? .requestFailed("Všechny pokusy selhaly"))
    }
}
