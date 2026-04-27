import Foundation

struct SHResultSchemaValidator {
    enum ValidationError: Error, LocalizedError {
        case invalidJSON
        case missingField(String)
        case invalidType(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "Invalid JSON payload"
            case .missingField(let field):
                return "Missing field: \(field)"
            case .invalidType(let field):
                return "Invalid type for field: \(field)"
            }
        }
    }

    private let requiredStringFields = [
        "source_file", "patient_name", "patient_id", "birth_date", "admission_date", "discharge_date", "discharge_status"
    ]

    private let requiredArrayFields = ["diagnoses", "medication", "lab_values", "warnings"]

    func decodeValidated(json: String) throws -> SHExtractionResult {
        let raw = extractJSONObject(from: json)
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError.invalidJSON
        }

        for key in requiredStringFields {
            guard object[key] != nil else { throw ValidationError.missingField(key) }
            guard object[key] is String else { throw ValidationError.invalidType(key) }
        }

        for key in requiredArrayFields {
            guard object[key] != nil else { throw ValidationError.missingField(key) }
            guard object[key] is [Any] else { throw ValidationError.invalidType(key) }
        }

        guard let confidenceValue = object["confidence"] else {
            throw ValidationError.missingField("confidence")
        }
        // `NSNumber` in Foundation boxes `Bool`, so `is NSNumber` accepts `true`/`false`.
        // Exclude booleans explicitly to avoid accepting `{"confidence": true}`.
        guard let number = confidenceValue as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else {
            throw ValidationError.invalidType("confidence")
        }
        _ = number

        let normalizedData = try JSONSerialization.data(withJSONObject: object, options: [])
        return try SHJSON.decoder().decode(SHExtractionResult.self, from: normalizedData)
    }

    /// Extracts the first balanced top-level JSON object from free-form text.
    /// The previous implementation took the substring between the first `{` and the
    /// last `}`, which broke on inputs like `"Result: {a} and also {b}"` – it would
    /// splice the two objects into invalid JSON. This version counts braces,
    /// respects string literals, and handles escapes.
    func extractJSONObject(from text: String) -> String {
        var depth = 0
        var startIndex: String.Index? = nil
        var insideString = false
        var escape = false

        for index in text.indices {
            let ch = text[index]

            if escape {
                escape = false
                continue
            }
            if ch == "\\" {
                escape = true
                continue
            }
            if ch == "\"" {
                insideString.toggle()
                continue
            }
            if insideString { continue }

            if ch == "{" {
                if depth == 0 { startIndex = index }
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0, let startIndex {
                    return String(text[startIndex...index])
                }
                if depth < 0 { depth = 0 }
            }
        }
        // Fallback: no balanced object found – return the original so the caller's
        // `JSONSerialization` throws a meaningful error.
        return text
    }
}
