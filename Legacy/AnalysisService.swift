import Foundation

struct AnalysisService: AnalysisServicing {
    let analysisController: AnalysisRunController
    let lmStudioURL: String
    let lmStudioAPIToken: String
    let sharedTimeout: SharedTimeout
    var timeout: TimeInterval { sharedTimeout.value }
    let useStreaming: Bool
    let temperature: Double
    let onRequestSent: @Sendable () -> Void
    let onStatus: @Sendable (String) -> Void

    func isContextLimitError(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("context length")
            || normalized.contains("context window")
            || normalized.contains("number of tokens to keep")
            || normalized.contains("provide a shorter input")
            || normalized.contains("prompt is too long")
            || normalized.contains("exceeded the context")
    }

    func sendSinglePrompt(
        promptText: String,
        modelName: String
    ) async throws -> (response: String, duration: TimeInterval) {
        try await sendToLMStudio(text: promptText, modelName: modelName)
    }

    func analyzeChunkWithRetry(
        chunk: String,
        promptText: String,
        modelName: String,
        minimumChunkSize: Int = 500
    ) async throws -> (responses: [String], duration: TimeInterval) {
        let requestText = "\(promptText)\n\n\(chunk)"

        do {
            let (response, duration) = try await sendToLMStudio(text: requestText, modelName: modelName)

            guard isContextLimitError(response), chunk.count > minimumChunkSize else {
                return ([response.trimmingCharacters(in: .whitespacesAndNewlines)], duration)
            }

            let reducedChunkSize = max(minimumChunkSize, chunk.count / 2)
            onStatus("Text je příliš dlouhý pro model — zkracuji a zkouším znovu...")
            let nestedChunks = PipelineProfile.chunkText(
                chunk,
                chunkSize: reducedChunkSize,
                chunkOverlap: min(120, max(40, reducedChunkSize / 8))
            )

            guard nestedChunks.count > 1 else {
                return ([response.trimmingCharacters(in: .whitespacesAndNewlines)], duration)
            }

            var nestedResponses: [String] = []
            var totalDuration = duration

            for nestedChunk in nestedChunks {
                try Task.checkCancellation()
                let nestedResult = try await analyzeChunkWithRetry(
                    chunk: nestedChunk,
                    promptText: promptText,
                    modelName: modelName,
                    minimumChunkSize: minimumChunkSize
                )
                nestedResponses.append(contentsOf: nestedResult.responses)
                totalDuration += nestedResult.duration
            }

            return (nestedResponses, totalDuration)
        } catch is CancellationError {
            throw AnalysisError.cancelled
        } catch let error as AnalysisError {
            throw error
        }
    }

    func summarizeWithRetry(
        summaries: [String],
        template: String,
        modelName: String,
        initialCharacterLimit: Int
    ) async throws -> (summary: String, duration: TimeInterval) {
        let joinedSummaries = summaries.joined(separator: "\n\n")
        var characterLimit = min(initialCharacterLimit, joinedSummaries.count)
        let minimumLimit = max(1200, min(characterLimit, 2400))
        var totalDuration: TimeInterval = 0
        var lastResponse = joinedSummaries

        while characterLimit >= minimumLimit {
            try Task.checkCancellation()

            let promptText = "\(template)\n\(joinedSummaries.prefix(characterLimit))"

            do {
                let (response, duration) = try await sendToLMStudio(text: promptText, modelName: modelName)
                totalDuration += duration
                lastResponse = response

                if !isContextLimitError(response) {
                    return (response.trimmingCharacters(in: .whitespacesAndNewlines), totalDuration)
                }

                onStatus("Překročen limit modelu, zkracuji finální souhrn a opakuji požadavek...")
                characterLimit = Int(Double(characterLimit) * 0.65)
            } catch is CancellationError {
                throw AnalysisError.cancelled
            } catch let error as AnalysisError {
                throw error
            }
        }

        return (lastResponse.trimmingCharacters(in: .whitespacesAndNewlines), totalDuration)
    }

    func analyzeWithVision(
        images: [Data],
        promptText: String,
        modelName: String
    ) async throws -> (response: String, duration: TimeInterval) {
        try Task.checkCancellation()
        onRequestSent()

        guard let url = Self.normalizeCompletionsURL(lmStudioURL) else {
            throw AnalysisError.invalidURL
        }

        guard !modelName.isEmpty else {
            throw AnalysisError.invalidModelName
        }

        guard !images.isEmpty else {
            throw AnalysisError.connectionFailed("Vision analýza vyžaduje alespoň jeden obrázek")
        }

        // Build multimodal content array: text prompt + image_url entries
        var contentParts: [[String: Any]] = [
            ["type": "text", "text": promptText]
        ]
        for imageData in images {
            let base64 = imageData.base64EncodedString()
            contentParts.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
            ])
        }

        let payload: [String: Any] = [
            "model": modelName,
            "messages": [["role": "user", "content": contentParts]],
            "stream": useStreaming,
            "temperature": temperature
        ]

        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AnalysisError.jsonSerializationFailed
        }

        let totalImageKB = images.reduce(0) { $0 + $1.count } / 1024
        onStatus("Odesílám \(images.count) obrázek/ů (\(totalImageKB) KB) na vision model...")

        let start = Date()

        // Streaming path for vision
        if useStreaming {
            var lastError: AnalysisError?
            for attempt in 0...Self.maxRetries {
                try Task.checkCancellation()

                let streamHandler = LMStudioStreamHandler()
                let streamID = UUID()
                analysisController.register(stream: streamHandler, id: streamID)

                onStatus("Vision data odeslána · model generuje odpověď (stream)...")

                let result = await withTaskCancellationHandler {
                    await streamHandler.sendStreamRequest(
                        to: url,
                        payload: payload,
                        timeout: timeout,
                        bearerToken: lmStudioAPIToken
                    )
                } onCancel: {
                    streamHandler.cancel()
                }

                analysisController.unregisterStream(id: streamID)
                let duration = Date().timeIntervalSince(start)

                switch result {
                case .success(let response):
                    onStatus("Vision model odpověděl (\(Int(duration))s)")
                    return (response.isEmpty ? "[Žádná odpověď]" : response.trimmingCharacters(in: .whitespacesAndNewlines), duration)
                case .failure(let error):
                    let msg = error.localizedDescription
                    if (msg.contains("429") || msg.contains("503")) && attempt < Self.maxRetries {
                        let delay = retryDelay(forAttempt: attempt, retryAfterHeader: nil)
                        onStatus("Vision model přetížen, čekám \(Int(delay))s...")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        lastError = .connectionFailed(msg)
                        continue
                    }
                    throw AnalysisError.connectionFailed(msg)
                }
            }
            throw lastError ?? AnalysisError.connectionFailed("Retry limit exceeded")
        }

        // Non-streaming path
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedToken = lmStudioAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeout

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw AnalysisError.jsonSerializationFailed
        }
        request.httpBody = jsonData

        var lastError: AnalysisError?
        for attempt in 0...Self.maxRetries {
            try Task.checkCancellation()

            let taskID = UUID()
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
                                    domain: "AnalysisService",
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
                analysisController.cancel()
            }

            analysisController.unregisterTask(id: taskID)
            let duration = Date().timeIntervalSince(start)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AnalysisError.connectionFailed("Neplatná odpověď serveru")
            }

            let statusCode = httpResponse.statusCode
            if Self.retryableStatusCodes.contains(statusCode) && attempt < Self.maxRetries {
                let delay = retryDelay(forAttempt: attempt, retryAfterHeader: nil)
                onStatus("Vision model přetížen (\(statusCode)), čekám \(Int(delay))s...")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = .connectionFailed("HTTP \(statusCode)")
                continue
            }

            guard (200...299).contains(statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw AnalysisError.connectionFailed("HTTP \(statusCode): \(body)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                return ("[Nepodařilo se parsovat odpověď vision modelu]", duration)
            }

            onStatus("Vision model odpověděl (\(Int(duration))s)")
            return (content.trimmingCharacters(in: .whitespacesAndNewlines), duration)
        }
        throw lastError ?? AnalysisError.connectionFailed("Retry limit exceeded")
    }

    private static let retryableStatusCodes: Set<Int> = [429, 503]
    private static let maxRetries = 3
    private static let baseRetryDelay: TimeInterval = 2.0

    private func retryDelay(forAttempt attempt: Int, retryAfterHeader: String?) -> TimeInterval {
        if let header = retryAfterHeader, let seconds = Double(header) {
            return seconds
        }
        return Self.baseRetryDelay * pow(2.0, Double(attempt))
    }

    static func normalizeCompletionsURL(_ rawURL: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }

        let path = url.path.lowercased()
        if path.hasSuffix("/v1/chat/completions") || path.hasSuffix("/chat/completions") {
            return url
        }

        // Auto-append /v1/chat/completions if missing
        var base = trimmed
        while base.hasSuffix("/") { base = String(base.dropLast()) }

        if path.hasSuffix("/v1") {
            return URL(string: "\(base)/chat/completions")
        }

        return URL(string: "\(base)/v1/chat/completions")
    }

    func sendToLMStudio(text: String, modelName: String) async throws -> (String, TimeInterval) {
        try Task.checkCancellation()

        onRequestSent()

        guard let url = Self.normalizeCompletionsURL(lmStudioURL) else {
            throw AnalysisError.invalidURL
        }

        guard !modelName.isEmpty else {
            throw AnalysisError.invalidModelName
        }

        let payload: [String: Any] = [
            "model": modelName,
            "messages": [["role": "user", "content": text]],
            "stream": useStreaming,
            "temperature": temperature
        ]

        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AnalysisError.jsonSerializationFailed
        }

        let inputSize = text.count
        let inputKB = String(format: "%.0f", Double(inputSize) / 1024.0)
        let estimatedTokens = max(1, inputSize / 4)
        onStatus("Odesílám data na server (\(inputKB) KB, ~\(estimatedTokens) tokenů)...")

        let start = Date()

        if useStreaming {
            var lastError: AnalysisError?
            for attempt in 0...Self.maxRetries {
                try Task.checkCancellation()

                let streamHandler = LMStudioStreamHandler()
                let streamID = UUID()
                analysisController.register(stream: streamHandler, id: streamID)

                onStatus("Data odeslána · model generuje odpověď (stream)...")

                let result = await withTaskCancellationHandler {
                    await streamHandler.sendStreamRequest(
                        to: url,
                        payload: payload,
                        timeout: timeout,
                        bearerToken: lmStudioAPIToken
                    )
                } onCancel: {
                    streamHandler.cancel()
                }

                analysisController.unregisterStream(id: streamID)
                let duration = Date().timeIntervalSince(start)

                switch result {
                case .success(let response):
                    onStatus("Model odpověděl (\(Int(duration))s)")
                    if response.isEmpty {
                        return ("[Žádná odpověď]", duration)
                    }
                    return (response, duration)
                case .failure(let error):
                    let errorMessage = error.localizedDescription
                    let is429 = errorMessage.contains("429")
                    let is503 = errorMessage.contains("503")

                    if (is429 || is503) && attempt < Self.maxRetries {
                        let statusCode = is429 ? 429 : 503
                        let delay = retryDelay(forAttempt: attempt, retryAfterHeader: nil)
                        onStatus("Server je přetížený (\(statusCode)), čekám \(Int(delay))s...")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        lastError = .connectionFailed(errorMessage)
                        continue
                    }

                    throw AnalysisError.connectionFailed(errorMessage)
                }
            }
            throw lastError ?? AnalysisError.connectionFailed("Retry limit exceeded")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedToken = lmStudioAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeout

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw AnalysisError.jsonSerializationFailed
        }
        request.httpBody = jsonData

        var lastHTTPError: AnalysisError?
        for attempt in 0...Self.maxRetries {
            try Task.checkCancellation()

            let taskID = UUID()
            onStatus("Data odeslána · model generuje odpověď...")

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
                                        domain: "AnalysisService",
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
                let elapsed = Int(Date().timeIntervalSince(start))

                let responseSize = data.count
                let responseKB = String(format: "%.0f", Double(responseSize) / 1024.0)
                onStatus("Model odpověděl (\(responseKB) KB, \(elapsed)s)")

                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

                    if Self.retryableStatusCodes.contains(statusCode) && attempt < Self.maxRetries {
                        let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                        let delay = retryDelay(forAttempt: attempt, retryAfterHeader: retryAfter)
                        onStatus("Server je přetížený (\(statusCode)), čekám \(Int(delay))s...")
                        lastHTTPError = .httpError(statusCode: statusCode, body: body)
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }

                    throw AnalysisError.httpError(statusCode: statusCode, body: body)
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let message = choices.first?["message"] as? [String: Any] {
                    // Standard OpenAI format: content field
                    if let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return (content, Date().timeIntervalSince(start))
                    }
                    // Reasoning models (Qwen 3.5, etc.): reasoning_content field
                    if let reasoningContent = message["reasoning_content"] as? String, !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Some models return reasoning in reasoning_content and answer in content
                        // If content is empty/null but reasoning_content has value, use reasoning_content
                        return (reasoningContent, Date().timeIntervalSince(start))
                    }
                    // Fallback: try any string value in message
                    for (_, value) in message {
                        if let str = value as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return (str, Date().timeIntervalSince(start))
                        }
                    }
                }

                // Log raw response for debugging
                let rawBody = String(data: data, encoding: .utf8) ?? "<binary>"
                let preview = String(rawBody.prefix(500))
                throw AnalysisError.invalidResponseFormat(detail: preview)
            } catch is CancellationError {
                analysisController.unregisterTask(id: taskID)
                throw AnalysisError.cancelled
            } catch let error as AnalysisError {
                analysisController.unregisterTask(id: taskID)
                if case .httpError(let code, _) = error, Self.retryableStatusCodes.contains(code), attempt < Self.maxRetries {
                    continue
                }
                throw error
            } catch {
                analysisController.unregisterTask(id: taskID)
                if Task.isCancelled {
                    throw AnalysisError.cancelled
                }
                throw AnalysisError.connectionFailed(error.localizedDescription)
            }
        }
        throw lastHTTPError ?? AnalysisError.connectionFailed("Retry limit exceeded")
    }
}
