import Foundation

struct ModelSnapshot {
    let modelID: String
    let detectedContextLimit: Int?
    let loadedContextLimit: Int?
    let maximumContextLimit: Int?
    let modelType: String?
    let modelState: String?
}

struct DiagnosticsService {
    func lmStudioEndpointIssueMessage(statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return "Neautorizováno (401) – neplatný nebo chybějící LM Studio API token."
        case 403:
            return "Přístup odmítnut (403) – token nemá potřebná oprávnění."
        case 404:
            return "API endpoint nenalezen (404) – zkontroluj URL serveru."
        case 429:
            return "Příliš mnoho požadavků (429) – zkus to znovu za chvíli."
        case 500...599:
            return "LM Studio hlásí interní chybu (\(statusCode))."
        default:
            return "LM Studio vrátilo HTTP \(statusCode)."
        }
    }

    func baseServerURL(from lmStudioURL: String) -> URL? {
        guard let url = URL(string: lmStudioURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme,
              let host = url.host else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }

    func modelListURL(from lmStudioURL: String) -> URL? {
        guard let baseURL = baseServerURL(from: lmStudioURL) else { return nil }
        return baseURL.appending(path: "v1/models")
    }

    func nativeModelListURL(from lmStudioURL: String) -> URL? {
        guard let baseURL = baseServerURL(from: lmStudioURL) else { return nil }
        return baseURL.appending(path: "api/v1/models")
    }

    func legacyNativeModelListURL(from lmStudioURL: String) -> URL? {
        guard let baseURL = baseServerURL(from: lmStudioURL) else { return nil }
        return baseURL.appending(path: "api/v0/models")
    }

    func fetchModelSnapshot(lmStudioURL: String, apiToken: String = "", timeout: TimeInterval) async -> ModelSnapshot? {
        let result = await fetchModelListResult(lmStudioURL: lmStudioURL, apiToken: apiToken, timeout: timeout)
        return result.snapshot
    }

    func fetchModelListResult(lmStudioURL: String, apiToken: String = "", timeout: TimeInterval, preferredModelID: String? = nil) async -> ModelListResult {
        guard let modelURL = modelListURL(from: lmStudioURL) else {
            return ModelListResult(snapshot: nil, allModelIDs: [])
        }

        guard let modelsData = await fetchData(from: modelURL, apiToken: apiToken, timeout: min(timeout, 30)) else {
            return ModelListResult(snapshot: nil, allModelIDs: [])
        }

        let allIDs = parseAllModelIDs(from: modelsData)
        guard !allIDs.isEmpty else {
            return ModelListResult(snapshot: nil, allModelIDs: [])
        }

        // Use preferred model if available, otherwise first
        let modelID: String
        if let preferred = preferredModelID, allIDs.contains(preferred) {
            modelID = preferred
        } else {
            modelID = allIDs[0]
        }

        let detectedContextLimit = parseContextLength(from: modelsData, preferredModelID: modelID)

        let nativeCandidates = [nativeModelListURL(from: lmStudioURL), legacyNativeModelListURL(from: lmStudioURL)]
            .compactMap { $0 }

        for nativeURL in nativeCandidates {
            guard let nativeData = await fetchData(from: nativeURL, apiToken: apiToken, timeout: min(timeout, 20)) else {
                continue
            }

            let runtimeInfo = parseModelRuntimeInfo(from: nativeData, preferredModelID: modelID)
            if runtimeInfo.loaded != nil || runtimeInfo.max != nil || runtimeInfo.type != nil || runtimeInfo.state != nil {
                let snapshot = ModelSnapshot(
                    modelID: modelID,
                    detectedContextLimit: runtimeInfo.loaded ?? runtimeInfo.max ?? detectedContextLimit,
                    loadedContextLimit: runtimeInfo.loaded,
                    maximumContextLimit: runtimeInfo.max,
                    modelType: runtimeInfo.type,
                    modelState: runtimeInfo.state
                )
                return ModelListResult(snapshot: snapshot, allModelIDs: allIDs)
            }
        }

        let snapshot = ModelSnapshot(
            modelID: modelID,
            detectedContextLimit: detectedContextLimit,
            loadedContextLimit: nil,
            maximumContextLimit: detectedContextLimit,
            modelType: nil,
            modelState: nil
        )
        return ModelListResult(snapshot: snapshot, allModelIDs: allIDs)
    }

    func diagnoseModelEndpointIssue(lmStudioURL: String, apiToken: String = "", timeout: TimeInterval) async -> String {
        guard let modelURL = modelListURL(from: lmStudioURL) else {
            return "Neplatná URL adresa LM Studia."
        }

        var request = URLRequest(url: modelURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = min(timeout, 20)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return "LM Studio nevrátilo platnou HTTP odpověď."
            }
            if (200...299).contains(httpResponse.statusCode) {
                return "Spojení navázáno, ale nepodařilo se přečíst modely."
            }
            return lmStudioEndpointIssueMessage(statusCode: httpResponse.statusCode)
        } catch {
            return "Nedostupné (\(error.localizedDescription))"
        }
    }

    func resolveQdrantDiagnostic(
        qdrantURL: String,
        qdrantAPIKey: String,
        timeout: TimeInterval,
        qdrantIsExpected: Bool
    ) async -> DiagnosticItem {
        guard qdrantIsExpected else {
            return DiagnosticItem(title: "Qdrant", value: "Vypnuto", tone: .neutral)
        }

        let trimmedURL = qdrantURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              let url = URL(string: "\(trimmedURL.hasSuffix("/") ? String(trimmedURL.dropLast()) : trimmedURL)/collections") else {
            return DiagnosticItem(title: "Qdrant", value: "Bez URL", tone: .warning)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(timeout, 15)
        if !qdrantAPIKey.isEmpty {
            request.setValue(qdrantAPIKey, forHTTPHeaderField: "api-key")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return DiagnosticItem(title: "Qdrant", value: "Neznámý stav", tone: .warning)
            }

            if (200...299).contains(httpResponse.statusCode) {
                return DiagnosticItem(title: "Qdrant", value: "Připojeno", tone: .ok)
            }

            return DiagnosticItem(title: "Qdrant", value: "Chyba API", tone: .warning)
        } catch {
            return DiagnosticItem(title: "Qdrant", value: "Nedostupný", tone: .warning)
        }
    }

    struct HeartbeatResult {
        let reachable: Bool
        let latencyMs: Int
        let statusCode: Int?
        let errorMessage: String?
    }

    func pingLMStudio(lmStudioURL: String, apiToken: String) async -> HeartbeatResult {
        guard let modelURL = modelListURL(from: lmStudioURL) else {
            return HeartbeatResult(reachable: false, latencyMs: 0, statusCode: nil, errorMessage: "Neplatná URL")
        }

        var request = URLRequest(url: modelURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 8

        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            guard let httpResponse = response as? HTTPURLResponse else {
                return HeartbeatResult(reachable: false, latencyMs: latency, statusCode: nil, errorMessage: "Neplatná odpověď")
            }
            if (200...299).contains(httpResponse.statusCode) {
                return HeartbeatResult(reachable: true, latencyMs: latency, statusCode: httpResponse.statusCode, errorMessage: nil)
            }
            return HeartbeatResult(reachable: false, latencyMs: latency, statusCode: httpResponse.statusCode, errorMessage: lmStudioEndpointIssueMessage(statusCode: httpResponse.statusCode))
        } catch let error as URLError where error.code == .cancelled {
            return HeartbeatResult(reachable: false, latencyMs: 0, statusCode: nil, errorMessage: nil)
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return HeartbeatResult(reachable: false, latencyMs: latency, statusCode: nil, errorMessage: error.localizedDescription)
        }
    }

    func pingQdrant(qdrantURL: String, apiKey: String) async -> HeartbeatResult {
        let trimmedURL = qdrantURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              let url = URL(string: "\(trimmedURL.hasSuffix("/") ? String(trimmedURL.dropLast()) : trimmedURL)/collections") else {
            return HeartbeatResult(reachable: false, latencyMs: 0, statusCode: nil, errorMessage: "Bez URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }

        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            guard let httpResponse = response as? HTTPURLResponse else {
                return HeartbeatResult(reachable: false, latencyMs: latency, statusCode: nil, errorMessage: "Neplatná odpověď")
            }
            if (200...299).contains(httpResponse.statusCode) {
                return HeartbeatResult(reachable: true, latencyMs: latency, statusCode: httpResponse.statusCode, errorMessage: nil)
            }
            return HeartbeatResult(reachable: false, latencyMs: latency, statusCode: httpResponse.statusCode, errorMessage: "HTTP \(httpResponse.statusCode)")
        } catch let error as URLError where error.code == .cancelled {
            return HeartbeatResult(reachable: false, latencyMs: 0, statusCode: nil, errorMessage: nil)
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return HeartbeatResult(reachable: false, latencyMs: latency, statusCode: nil, errorMessage: error.localizedDescription)
        }
    }

    private func fetchData(from url: URL, apiToken: String, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    func parseFirstModelID(from data: Data?) -> String? {
        parseAllModelIDs(from: data).first
    }

    func parseAllModelIDs(from data: Data?) -> [String] {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            return []
        }

        return models.compactMap { $0["id"] as? String }
    }

    func parseContextLength(from data: Data?, preferredModelID: String? = nil) -> Int? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let preferredModelID,
           let modelObject = findModelObject(in: json, matching: preferredModelID),
           let contextLength = extractContextLength(from: modelObject) {
            return contextLength
        }

        return extractContextLength(from: json)
    }

    func parseModelRuntimeInfo(from data: Data?, preferredModelID: String) -> ModelRuntimeInfo {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data),
              let modelObject = findModelObject(in: json, matching: preferredModelID) else {
            return ModelRuntimeInfo(loaded: nil, max: nil, type: nil, state: nil)
        }

        let loaded = integerValue(from: modelObject["loaded_context_length"])
            ?? integerValue(from: modelObject["loadedContextLength"])
        let max = integerValue(from: modelObject["max_context_length"])
            ?? integerValue(from: modelObject["maxContextLength"])
            ?? extractContextLength(from: modelObject)
        let type = stringValue(from: modelObject["type"])
        let state = stringValue(from: modelObject["state"])

        return ModelRuntimeInfo(loaded: loaded, max: max, type: type, state: state)
    }

    private func findModelObject(in object: Any, matching modelID: String) -> [String: Any]? {
        let normalizedID = modelID.lowercased()

        if let dictionary = object as? [String: Any] {
            if let id = dictionary["id"] as? String,
               id.lowercased() == normalizedID {
                return dictionary
            }

            for value in dictionary.values {
                if let match = findModelObject(in: value, matching: modelID) {
                    return match
                }
            }
        }

        if let array = object as? [Any] {
            for item in array {
                if let match = findModelObject(in: item, matching: modelID) {
                    return match
                }
            }
        }

        return nil
    }

    private func extractContextLength(from object: Any) -> Int? {
        let keys = [
            "max_context_length",
            "context_length",
            "contextLength",
            "maxContextLength",
            "n_ctx",
            "max_seq_len",
            "max_position_embeddings"
        ]

        if let dictionary = object as? [String: Any] {
            for key in keys {
                if let value = integerValue(from: dictionary[key]) {
                    return value
                }
            }

            for value in dictionary.values {
                if let nested = extractContextLength(from: value) {
                    return nested
                }
            }
        }

        if let array = object as? [Any] {
            for item in array {
                if let nested = extractContextLength(from: item) {
                    return nested
                }
            }
        }

        return nil
    }

    private func integerValue(from value: Any?) -> Int? {
        switch value {
        case let intValue as Int:
            return intValue
        case let doubleValue as Double:
            return Int(doubleValue)
        case let stringValue as String:
            return Int(stringValue)
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }

    private func stringValue(from value: Any?) -> String? {
        switch value {
        case let stringValue as String:
            return stringValue
        case let customStringConvertible as CustomStringConvertible:
            return customStringConvertible.description
        default:
            return nil
        }
    }
}
