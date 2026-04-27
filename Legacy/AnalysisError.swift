import Foundation

enum AnalysisError: LocalizedError, Equatable {
    case connectionFailed(String)
    case httpError(statusCode: Int, body: String)
    case timeout
    case contextLimitExceeded
    case cancelled
    case invalidURL
    case invalidModelName
    case jsonSerializationFailed
    case emptyResponse
    case invalidResponseFormat(detail: String = "")

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail):
            return "Chyba připojení: \(detail)"
        case .httpError(let statusCode, let body):
            let shortBody = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            switch statusCode {
            case 401:
                return "Chyba LM Studio 401: Neplatný nebo chybějící API token.\n\(shortBody)"
            case 403:
                return "Chyba LM Studio 403: Přístup byl odmítnut.\n\(shortBody)"
            case 404:
                return "Chyba LM Studio 404: API endpoint nebyl nalezen.\n\(shortBody)"
            case 408:
                return "Chyba LM Studio 408: Vypršel čas požadavku.\n\(shortBody)"
            case 429:
                return "Chyba LM Studio 429: Příliš mnoho požadavků.\n\(shortBody)"
            case 500...599:
                return "Chyba LM Studio \(statusCode): Interní chyba serveru.\n\(shortBody)"
            default:
                return "Chyba LM Studio \(statusCode).\n\(shortBody)"
            }
        case .timeout:
            return "Chyba: vypršel časový limit požadavku."
        case .contextLimitExceeded:
            return "Chyba: překročen kontextový limit modelu."
        case .cancelled:
            return "Zpracování zrušeno uživatelem."
        case .invalidURL:
            return "Chyba: neplatná URL adresa API."
        case .invalidModelName:
            return "Chyba: nepodařilo se zjistit aktivní model v LM Studiu."
        case .jsonSerializationFailed:
            return "Chyba: JSON serializace selhala."
        case .emptyResponse:
            return "Chyba: prázdná odpověď serveru."
        case .invalidResponseFormat(let detail):
            if detail.isEmpty {
                return "Chyba: neplatný formát odpovědi."
            }
            return "Chyba: neplatný formát odpovědi.\n\(detail)"
        }
    }
}
