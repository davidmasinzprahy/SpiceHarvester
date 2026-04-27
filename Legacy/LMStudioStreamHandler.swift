//
//  LMStudioStreamHandler.swift
//  SpiceHarvester
//
//  Created by David Mašín on 24.06.2025.
//
import Foundation

class LMStudioStreamHandler: NSObject, URLSessionDataDelegate {
    private var responseText = ""
    private var pendingBuffer = ""
    private var errorBody = ""
    private var completion: ((String) -> Void)?
    private var errorHandler: ((String) -> Void)?
    private var didFinish = false
    private var responseStatusCode: Int?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    private func lmStudioHTTPErrorMessage(statusCode: Int, body: String) -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortBody = String(trimmedBody.prefix(600))

        switch statusCode {
        case 401:
            return "[Chyba LM Studio 401] Neplatný nebo chybějící API token. Zkontroluj pole \"LM Studio API token\" v Nastavení.\n\(shortBody)"
        case 403:
            return "[Chyba LM Studio 403] Přístup byl odmítnut. Token nemá potřebná oprávnění nebo server blokuje požadavek.\n\(shortBody)"
        case 404:
            return "[Chyba LM Studio 404] API endpoint nebyl nalezen. Zkontroluj URL adresu serveru.\n\(shortBody)"
        case 408:
            return "[Chyba LM Studio 408] Vypršel čas požadavku. Server odpovídá příliš pomalu.\n\(shortBody)"
        case 429:
            return "[Chyba LM Studio 429] Příliš mnoho požadavků najednou. Sniž souběžné požadavky nebo zkus opakovat později.\n\(shortBody)"
        case 500...599:
            return "[Chyba LM Studio \(statusCode)] Interní chyba serveru.\n\(shortBody)"
        default:
            return "[Chyba LM Studio \(statusCode)]\n\(shortBody)"
        }
    }

    func sendStreamRequest(
        to url: URL,
        payload: [String: Any],
        timeout: TimeInterval,
        bearerToken: String? = nil,
        completion: @escaping (String) -> Void,
        errorHandler: @escaping (String) -> Void
    ) {
        responseText = ""
        pendingBuffer = ""
        errorBody = ""
        didFinish = false
        responseStatusCode = nil
        self.completion = completion
        self.errorHandler = errorHandler

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            let trimmed = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
            }
        }
        request.timeoutInterval = timeout

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            errorHandler("[Chyba serializace JSON]")
            return
        }

        request.httpBody = body

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        task.resume()
    }

    func sendStreamRequest(
        to url: URL,
        payload: [String: Any],
        timeout: TimeInterval,
        bearerToken: String? = nil
    ) async -> Result<String, NSError> {
        await withCheckedContinuation { continuation in
            sendStreamRequest(
                to: url,
                payload: payload,
                timeout: timeout,
                bearerToken: bearerToken,
                completion: { response in
                    continuation.resume(returning: .success(response))
                },
                errorHandler: { error in
                    let streamError = NSError(
                        domain: "LMStudioStreamHandler",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error]
                    )
                    continuation.resume(returning: .failure(streamError))
                }
            )
        }
    }

    func cancel() {
        didFinish = true
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let statusCode = responseStatusCode, statusCode != 200 {
            if let chunk = String(data: data, encoding: .utf8) {
                errorBody += chunk
            }
            return
        }

        guard let chunk = String(data: data, encoding: .utf8) else { return }
        pendingBuffer += chunk

        let lines = pendingBuffer.components(separatedBy: "\n")
        let hasCompleteTail = pendingBuffer.hasSuffix("\n")
        let completeLines = hasCompleteTail ? lines : Array(lines.dropLast())
        pendingBuffer = hasCompleteTail ? "" : (lines.last ?? "")

        for rawLine in completeLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data: ") else { continue }

            let jsonPart = line.dropFirst(6)
            if jsonPart == "[DONE]" {
                didFinish = true
                session.invalidateAndCancel()
                task = nil
                self.session = nil
                completion?(responseText)
                return
            }

            guard let jsonData = jsonPart.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                continue
            }

            responseText += content
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            responseStatusCode = http.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.task = nil
        self.session = nil
        guard !didFinish else { return }

        if let error = error {
            errorHandler?("[Stream: chyba připojení: \(error.localizedDescription)]")
        } else if let statusCode = responseStatusCode, statusCode != 200 {
            errorHandler?(lmStudioHTTPErrorMessage(statusCode: statusCode, body: errorBody))
        } else {
            completion?(responseText)
        }
    }
}
