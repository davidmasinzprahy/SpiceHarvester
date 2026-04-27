import Foundation
import os

// MARK: – Wire models (OpenAI-compatible)

struct SHLMModelInfo: Codable, Hashable, Identifiable, Sendable {
    let id: String
}

struct SHModelListResponse: Codable, Sendable {
    let data: [SHLMModelInfo]
}

struct SHChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct SHChatRequest: Codable, Sendable {
    let model: String
    let messages: [SHChatMessage]
    let temperature: Double
    // Note: response_format is intentionally NOT sent. Different LM Studio versions
    // / model runtimes accept different values ("json_object" vs "json_schema" vs "text").
    // Omitting the field lets the server pick its default (text) and the prompt itself
    // drives the expected output format – works with any backend.
}

struct SHChatResponse: Codable, Sendable {
    struct Choice: Codable, Sendable {
        /// Reasoning/"thinking" models (Qwen3, DeepSeek-R1, o1-style) emit the
        /// visible answer into `content` and their internal chain-of-thought into
        /// a separate `reasoning_content` field. Some deployments route the whole
        /// answer into `reasoning_content` when no `</think>` tag closes the
        /// trace, leaving `content` empty — then the useful JSON is only
        /// recoverable from the reasoning stream. We accept both and prefer
        /// `content` when non-empty.
        struct Message: Codable, Sendable {
            let role: String
            let content: String?
            let reasoning_content: String?

            /// The text we actually parse downstream. Non-empty `content` wins
            /// (that's the contract), otherwise falls through to reasoning_content,
            /// otherwise "" so the JSON decoder throws a clean SHLMError.emptyResponse.
            var effectiveContent: String {
                if let c = content, !c.isEmpty { return c }
                if let r = reasoning_content, !r.isEmpty { return r }
                return ""
            }
        }
        let message: Message
    }
    let choices: [Choice]
}

struct SHVisionChatMessage: Encodable, Sendable {
    struct Content: Encodable, Sendable {
        struct ImageURL: Encodable, Sendable {
            let url: String
        }

        let type: String
        let text: String?
        let image_url: ImageURL?

        static func text(_ text: String) -> Content {
            Content(type: "text", text: text, image_url: nil)
        }

        static func image(dataURL: String) -> Content {
            Content(type: "image_url", text: nil, image_url: ImageURL(url: dataURL))
        }
    }

    let role: String
    let content: [Content]
}

struct SHVisionChatRequest: Encodable, Sendable {
    let model: String
    let messages: [SHVisionChatMessage]
    let temperature: Double
}

struct SHEmbeddingRequest: Codable, Sendable {
    let model: String
    let input: String
}

struct SHEmbeddingBatchRequest: Codable, Sendable {
    let model: String
    let input: [String]
}

struct SHEmbeddingResponse: Codable, Sendable {
    struct Item: Codable, Sendable {
        let index: Int?
        let embedding: [Double]
    }
    let data: [Item]
}

struct SHRerankRequest: Codable, Sendable {
    let model: String
    let query: String
    let documents: [String]
    let top_n: Int?
}

struct SHRerankResponse: Codable, Sendable {
    struct Result: Codable, Sendable {
        let index: Int?
        let relevance_score: Double?
        let score: Double?

        var effectiveScore: Double {
            relevance_score ?? score ?? 0
        }
    }

    let results: [Result]?
    let data: [Result]?

    var effectiveResults: [Result] {
        results ?? data ?? []
    }
}

// MARK: – LM Studio native REST API (/api/v0)
//
// The OpenAI-compatible `/v1/models` endpoint only returns model IDs, not the
// actual context window. LM Studio ≥ 0.3.0 additionally exposes a native REST
// API at `/api/v0` that includes rich per-model metadata. We use this to
// auto-populate `config.modelContextTokens` on server verification so the user
// doesn't have to guess.

struct SHLMStudioLoadedModel: Codable, Sendable {
    let id: String
    let type: String?
    let state: String?
    let max_context_length: Int?
    let loaded_context_length: Int?

    /// The context window that's actually usable right now. LM Studio may load a
    /// model with a smaller context than its maximum (to save RAM), in which case
    /// requests are bounded by `loaded_context_length`. Falls back to the max.
    var effectiveContextLength: Int? {
        loaded_context_length ?? max_context_length
    }
}

struct SHLMStudioLoadedModelsResponse: Codable, Sendable {
    let data: [SHLMStudioLoadedModel]
}

// Server-side tokenization: LM Studio's native API exposes a tokenizer so the
// client can count tokens exactly instead of guessing from `chars / N`. Used
// in the CONSOLIDATE preflight; falls back to the character heuristic when the
// endpoint isn't available (non-LM-Studio backends, older versions).

struct SHTokenizeRequestBody: Codable, Sendable {
    let model: String
    let text: String
}

/// Flexible decoder — different LM Studio releases have shipped slightly
/// different response shapes. Accepts `{tokens: [...]}`, `{count: N}`, or
/// `{token_count: N}` and returns the first non-nil value.
struct SHTokenizeResponseBody: Codable, Sendable {
    let tokens: [Int]?
    let count: Int?
    let token_count: Int?

    var effectiveCount: Int? {
        count ?? token_count ?? tokens?.count
    }
}

// MARK: – Error type

enum SHLMError: Error, LocalizedError, Sendable {
    case badURL(String)
    case http(status: Int, body: String)
    case emptyResponse
    case emptyEmbedding

    var errorDescription: String? {
        switch self {
        case .badURL(let s):
            return "Neplatná URL serveru: \(s)"
        case .http(let status, let body):
            let snippet = body.count > 240 ? String(body.prefix(240)) + "…" : body
            return "HTTP \(status): \(snippet)"
        case .emptyResponse:
            return "Server vrátil prázdnou odpověď (žádné `choices`)."
        case .emptyEmbedding:
            return "Server vrátil prázdný embedding vektor."
        }
    }
}

// MARK: – Client

/// OpenAI-compatible chat/embeddings client for local AI backends.
/// Stateless (only holds the `URLSession`), safe to share across actors/tasks.
final class SHOpenAICompatibleClient: Sendable {
    private let session: URLSession
    /// Number of retry attempts on transient errors. 1 = no retry, 3 = up to 2 retries
    /// with exponential backoff (1 s → 3 s). Kept modest so a genuinely down server
    /// doesn't block the user for minutes.
    private let maxAttempts: Int
    /// Retry attempts visible in Console.app (subsystem filter
    /// `com.spiceharvester`, category `OpenAICompatibleClient`). processing.log stays
    /// focused on inference milestones.
    private let log = Logger(subsystem: "com.spiceharvester", category: "OpenAICompatibleClient")

    /// Creates a client with user-tunable per-request timeout.
    /// - Parameters:
    ///   - session: pre-configured session override (tests); when `nil` a default
    ///     one is built with the given `requestTimeoutSeconds`.
    ///   - maxAttempts: retry count for transient errors (default 3).
    ///   - requestTimeoutSeconds: per-request timeout. Short values detect stuck
    ///     models fast; longer values tolerate slow hardware. Clamped to 60–3600.
    ///     Default 600 s matches `SHAppConfig.requestTimeoutSeconds`.
    init(
        session: URLSession? = nil,
        maxAttempts: Int = 3,
        requestTimeoutSeconds: Int = 600
    ) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // Clamp to [60, 3600] so a misconfigured value can't wedge the app
            // (e.g. 0 → every request throws immediately).
            config.timeoutIntervalForRequest = TimeInterval(max(60, min(3600, requestTimeoutSeconds)))
            // Resource timeout stays at 1 h to accommodate map-reduce chains made
            // of many sub-requests that each fit inside their own request timeout.
            config.timeoutIntervalForResource = 3_600
            self.session = URLSession(configuration: config)
        }
        self.maxAttempts = max(1, maxAttempts)
    }

    func verifyServer(_ server: SHServerConfig) async throws {
        _ = try await fetchModels(server)
    }

    func fetchModels(_ server: SHServerConfig) async throws -> [String] {
        let modelsURL = try endpoint(server: server, path: "/models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        if !server.apiKey.isEmpty {
            request.addValue("Bearer \(server.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await send(request)
        let decoded = try SHJSON.decoder().decode(SHModelListResponse.self, from: data)
        return decoded.data.map(\.id)
    }

    /// LM Studio-specific: returns rich metadata including context length for each
    /// loaded model. Throws if the endpoint isn't present (e.g. user pointed the
    /// base URL at vanilla OpenAI API or a non-LM-Studio server), so callers
    /// should treat the failure as "context unknown, keep the configured default".
    func fetchLoadedModels(_ server: SHServerConfig) async throws -> [SHLMStudioLoadedModel] {
        let url = try lmStudioNativeEndpoint(server: server, path: "/api/v0/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !server.apiKey.isEmpty {
            request.addValue("Bearer \(server.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await send(request)
        let decoded = try SHJSON.decoder().decode(SHLMStudioLoadedModelsResponse.self, from: data)
        return decoded.data
    }

    /// LM Studio-specific: counts tokens server-side using the loaded model's
    /// own tokenizer. Accurate — no more "chars / N" heuristics. Returns `nil`
    /// (not throws) when the endpoint isn't available so callers can gracefully
    /// fall back to character-based estimation.
    ///
    /// Used in the CONSOLIDATE preflight: when available, prevents both false
    /// positives (we blocked requests that would actually fit) and false
    /// negatives (we let through requests that overflow and time out after an
    /// hour — the scenario that motivated this feature).
    func countTokens(server: SHServerConfig, model: String, text: String) async -> Int? {
        guard let url = try? lmStudioNativeEndpoint(server: server, path: "/api/v0/tokenize") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.apiKey.isEmpty {
            request.addValue("Bearer \(server.apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let body = try? SHJSON.encoder().encode(SHTokenizeRequestBody(model: model, text: text)) else {
            return nil
        }
        request.httpBody = body

        do {
            let (data, _) = try await send(request)
            let decoded = try SHJSON.decoder().decode(SHTokenizeResponseBody.self, from: data)
            return decoded.effectiveCount
        } catch {
            return nil
        }
    }

    func chatJSON(
        server: SHServerConfig,
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let chatURL = try endpoint(server: server, path: "/chat/completions")
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.apiKey.isEmpty {
            request.addValue("Bearer \(server.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let payload = SHChatRequest(
            model: model,
            messages: [
                SHChatMessage(role: "system", content: systemPrompt),
                SHChatMessage(role: "user", content: userPrompt)
            ],
            temperature: 0
        )

        request.httpBody = try SHJSON.encoder(prettyPrinted: false).encode(payload)
        let (data, _) = try await send(request)
        let decoded = try SHJSON.decoder().decode(SHChatResponse.self, from: data)
        guard let first = decoded.choices.first else {
            throw SHLMError.emptyResponse
        }
        return first.message.effectiveContent
    }

    func visionText(
        server: SHServerConfig,
        model: String,
        prompt: String,
        imageDataURL: String
    ) async throws -> String {
        let chatURL = try endpoint(server: server, path: "/chat/completions")
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.apiKey.isEmpty {
            request.addValue("Bearer \(server.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let payload = SHVisionChatRequest(
            model: model,
            messages: [
                SHVisionChatMessage(
                    role: "user",
                    content: [
                        .text(prompt),
                        .image(dataURL: imageDataURL)
                    ]
                )
            ],
            temperature: 0
        )

        request.httpBody = try SHJSON.encoder(prettyPrinted: false).encode(payload)
        let (data, _) = try await send(request)
        let decoded = try SHJSON.decoder().decode(SHChatResponse.self, from: data)
        guard let first = decoded.choices.first else {
            throw SHLMError.emptyResponse
        }
        return first.message.effectiveContent
    }

    func embedding(server: SHServerConfig, model: String, input: String) async throws -> [Double] {
        guard let vector = try await embeddings(server: server, model: model, inputs: [input]).first else {
            throw SHLMError.emptyEmbedding
        }
        return vector
    }

    func supportsEmbeddings(server: SHServerConfig, model: String) async -> Bool {
        do {
            let vector = try await embedding(server: server, model: model, input: "embedding capability check")
            return !vector.isEmpty
        } catch {
            return false
        }
    }

    func rerank(
        server: SHServerConfig,
        model: String,
        query: String,
        documents: [String],
        topN: Int
    ) async throws -> [(index: Int, score: Double)] {
        guard !documents.isEmpty else { return [] }

        let url = try endpoint(server: server, path: "/rerank")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.apiKey.isEmpty {
            request.addValue("Bearer \(server.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try SHJSON.encoder(prettyPrinted: false).encode(
            SHRerankRequest(model: model, query: query, documents: documents, top_n: topN)
        )

        let (data, _) = try await send(request)
        let decoded = try SHJSON.decoder().decode(SHRerankResponse.self, from: data)
        return decoded.effectiveResults.compactMap { item in
            guard let index = item.index, documents.indices.contains(index) else { return nil }
            return (index, item.effectiveScore)
        }
    }

    func embeddings(server: SHServerConfig, model: String, inputs: [String]) async throws -> [[Double]] {
        guard !inputs.isEmpty else { return [] }

        let url = try endpoint(server: server, path: "/embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.apiKey.isEmpty {
            request.addValue("Bearer \(server.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if inputs.count == 1 {
            request.httpBody = try SHJSON.encoder(prettyPrinted: false).encode(SHEmbeddingRequest(model: model, input: inputs[0]))
        } else {
            request.httpBody = try SHJSON.encoder(prettyPrinted: false).encode(SHEmbeddingBatchRequest(model: model, input: inputs))
        }

        let (data, _) = try await send(request)
        let decoded = try SHJSON.decoder().decode(SHEmbeddingResponse.self, from: data)
        let ordered = decoded.data.enumerated()
            .sorted { lhs, rhs in
                (lhs.element.index ?? lhs.offset) < (rhs.element.index ?? rhs.offset)
            }
            .map(\.element.embedding)
        guard ordered.count == inputs.count, ordered.allSatisfy({ !$0.isEmpty }) else {
            throw SHLMError.emptyEmbedding
        }
        return ordered
    }

    // MARK: – Private

    /// Builds an endpoint URL from `server.baseURL + path` using `URLComponents`
    /// so query strings, fragments, and trailing slashes are handled correctly.
    private func endpoint(server: SHServerConfig, path: String) throws -> URL {
        guard let base = server.normalizedBaseURL else {
            throw SHLMError.badURL(server.baseURL)
        }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        // Strip trailing "/" from base path so we don't get "//models".
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var basePath = components?.path ?? base.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components?.path = basePath + normalizedPath
        guard let url = components?.url else {
            throw SHLMError.badURL(base.absoluteString + normalizedPath)
        }
        return url
    }

    /// LM Studio's native API lives at the server root (one level above `/v1`).
    /// Given a base URL of `http://localhost:1234/v1` and path `/api/v0/models`,
    /// produces `http://localhost:1234/api/v0/models`. If the base URL has no
    /// `/v1` suffix (user pasted `http://localhost:1234`), the path is simply
    /// appended to it.
    private func lmStudioNativeEndpoint(server: SHServerConfig, path: String) throws -> URL {
        guard let base = server.normalizedBaseURL else {
            throw SHLMError.badURL(server.baseURL)
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var basePath = components?.path ?? base.path
        // Strip trailing slashes and an optional "/v1" segment so the native API
        // sits at the root.
        while basePath.hasSuffix("/") { basePath.removeLast() }
        if basePath.hasSuffix("/v1") {
            basePath.removeLast(3)
        }
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        components?.path = basePath + normalizedPath
        guard let url = components?.url else {
            throw SHLMError.badURL(base.absoluteString + normalizedPath)
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SHLMError.http(status: -1, body: "Response is not HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            throw SHLMError.http(status: http.statusCode, body: body)
        }
    }

    /// Runs a request with exponential-backoff retry on transient failures:
    /// HTTP 502/503/504 (server overloaded / bad gateway / timeout), plus
    /// URLError cases that the OS marks as retriable (timedOut, networkConnectionLost,
    /// cannotConnectToHost — the last one covers LM Studio mid-restart). Anything
    /// else throws immediately so genuine errors aren't masked by retries.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                try validate(response: response, data: data)
                return (data, response)
            } catch {
                // Propagate cancellation without retry – user explicitly asked to stop.
                if error is CancellationError { throw error }
                if let urlError = error as? URLError, urlError.code == .cancelled { throw error }

                if attempt >= maxAttempts || !Self.isTransient(error: error) {
                    if attempt > 1 {
                        log.error("Giving up after \(attempt) attempts: \(error.localizedDescription, privacy: .public)")
                    }
                    throw error
                }
                // Exponential backoff: 1 s, 3 s, 9 s … capped at 10 s so we don't
                // push the user into a 30+ s retry window.
                let delaySeconds = min(10.0, pow(3.0, Double(attempt - 1)))
                log.warning("Transient error on attempt \(attempt)/\(self.maxAttempts), retrying in \(delaySeconds, format: .fixed(precision: 1))s: \(error.localizedDescription, privacy: .public)")
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
    }

    /// Decides whether the given error is worth retrying. Conservative: known
    /// transient conditions only.
    private static func isTransient(error: Error) -> Bool {
        if case SHLMError.http(let status, _) = error {
            return status == 502 || status == 503 || status == 504
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .cannotConnectToHost,
                 .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}
