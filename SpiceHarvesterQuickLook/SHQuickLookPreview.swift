import Foundation

// MARK: – Shared JSON factory

/// Shared factory for JSON encoders used by export and cache layers.
/// Prevents drift where one site sorts keys and another doesn't.
enum SHJSON {
    static func encoder(prettyPrinted: Bool = true, dateStrategy: JSONEncoder.DateEncodingStrategy = .iso8601) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = dateStrategy
        return encoder
    }

    static func decoder(dateStrategy: JSONDecoder.DateDecodingStrategy = .iso8601) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateStrategy
        return decoder
    }
}

// MARK: – Exporter

final class SHExportService {
    init() {}

    func exportAll(results: [SHExtractionResult], outputFolder: URL) throws {
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try exportJSON(results: results, outputFolder: outputFolder)
        try exportRawResponses(results: results, outputFolder: outputFolder)
        try exportTXT(results: results, outputFolder: outputFolder)
        try exportCSV(results: results, outputFolder: outputFolder)
    }

    /// Writes the LLM's raw output as proper files so the user doesn't have to dig
    /// through escaped JSON strings inside the canonical result. Three detection paths,
    /// in order of preference:
    ///
    ///   1. `=====CSV=====` / `=====TXT=====` markers → writes `{name}_raw.csv` AND
    ///      `{name}_raw.txt` split on the markers. Designed for consolidate-mode
    ///      prompts that ask for tabular output + human summary in one response.
    ///   2. Valid JSON → writes `{name}_raw.json` pretty-printed.
    ///   3. Otherwise → writes `{name}_raw.txt` with the plain model output.
    ///
    /// Also writes an aggregate `raw_responses.json` map `{fileName: parsedValue}`
    /// for batch consumers.
    private func exportRawResponses(results: [SHExtractionResult], outputFolder: URL) throws {
        guard !results.isEmpty else { return }

        var used: Set<String> = []
        var aggregate: [String: Any] = [:]

        for result in results where !result.rawResponse.isEmpty {
            let base = URL(fileURLWithPath: result.source_file).deletingPathExtension().lastPathComponent
            let safe = base.isEmpty ? "document" : base
            var candidate = "\(safe)_raw"
            var counter = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(safe)_raw_\(counter)"
                counter += 1
            }
            used.insert(candidate.lowercased())

            // Path 1: CSV/TXT section split
            if let sections = parseCSVTXTSections(result.rawResponse) {
                let csvURL = outputFolder.appendingPathComponent("\(candidate).csv")
                let txtURL = outputFolder.appendingPathComponent("\(candidate).txt")
                let csvWithBOM = "\u{FEFF}" + sections.csv
                try csvWithBOM.write(to: csvURL, atomically: true, encoding: .utf8)
                try sections.txt.write(to: txtURL, atomically: true, encoding: .utf8)
                aggregate[base] = ["csv": sections.csv, "txt": sections.txt]
                continue
            }

            // Path 2: JSON
            if let data = result.rawResponse.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                let pretty = try JSONSerialization.data(
                    withJSONObject: parsed,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try pretty.write(to: outputFolder.appendingPathComponent("\(candidate).json"), options: .atomic)
                aggregate[base] = parsed
                continue
            }

            // Path 3: plain text fallback
            try result.rawResponse.write(
                to: outputFolder.appendingPathComponent("\(candidate).txt"),
                atomically: true,
                encoding: .utf8
            )
            aggregate[base] = result.rawResponse
        }

        if !aggregate.isEmpty {
            let aggregateData = try JSONSerialization.data(
                withJSONObject: aggregate,
                options: [.prettyPrinted, .sortedKeys]
            )
            try aggregateData.write(
                to: outputFolder.appendingPathComponent("raw_responses.json"),
                options: .atomic
            )
        }
    }

    /// Parses the prompt-convention `=====CSV=====` / `=====TXT=====` format into
    /// its two sections. Returns `nil` if the exact markers aren't present in the
    /// expected order, so JSON / plain-text fallback paths still run.
    private func parseCSVTXTSections(_ text: String) -> (csv: String, txt: String)? {
        let csvMarker = "=====CSV====="
        let txtMarker = "=====TXT====="
        guard let csvStart = text.range(of: csvMarker),
              let txtStart = text.range(of: txtMarker),
              csvStart.upperBound <= txtStart.lowerBound else {
            return nil
        }

        let csvBody = text[csvStart.upperBound..<txtStart.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let txtBody = text[txtStart.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !csvBody.isEmpty, !txtBody.isEmpty else { return nil }
        return (csv: csvBody, txt: txtBody)
    }

    private func exportJSON(results: [SHExtractionResult], outputFolder: URL) throws {
        let encoder = SHJSON.encoder()

        let allURL = outputFolder.appendingPathComponent("results.json")
        try encoder.encode(results).write(to: allURL, options: .atomic)

        var used: Set<String> = []
        for result in results {
            let base = URL(fileURLWithPath: result.source_file).deletingPathExtension().lastPathComponent
            let safe = base.isEmpty ? "document" : base
            var candidate = safe
            var counter = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(safe)_\(counter)"
                counter += 1
            }
            used.insert(candidate.lowercased())
            let url = outputFolder.appendingPathComponent("\(candidate).spice-result.json")
            try encoder.encode(result).write(to: url, options: .atomic)
        }
    }

    private func exportTXT(results: [SHExtractionResult], outputFolder: URL) throws {
        var text = ""
        for result in results {
            text += "Soubor: \(result.source_file)\n"
            text += "Pacient: \(result.patient_name)\n"
            text += "ID: \(result.patient_id)\n"
            text += "Přijetí: \(result.admission_date) | Propuštění: \(result.discharge_date)\n"
            text += "Diagnózy: \(result.diagnoses.joined(separator: ", "))\n"
            text += "Medikace: \(result.medication.joined(separator: ", "))\n"
            text += "Laboratorní hodnoty: \(result.lab_values.joined(separator: ", "))\n"
            text += "Stav: \(result.discharge_status)\n"
            text += "Confidence: \(String(format: "%.2f", result.confidence))\n"
            text += "Varování: \(result.warnings.joined(separator: "; "))\n"
            if !result.rawResponse.isEmpty {
                text += "--- Raw odpověď modelu ---\n"
                text += result.rawResponse + "\n"
            }
            text += "---------------------------------------------\n"
        }

        try text.write(to: outputFolder.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
    }

    private func exportCSV(results: [SHExtractionResult], outputFolder: URL) throws {
        let header = [
            "source_file", "patient_name", "patient_id", "birth_date", "admission_date", "discharge_date",
            "diagnoses", "medication", "lab_values", "discharge_status", "warnings", "confidence"
        ].joined(separator: ",")

        var rows = [header]
        rows.reserveCapacity(results.count + 1)

        for item in results {
            let fields = [
                item.source_file,
                item.patient_name,
                item.patient_id,
                item.birth_date,
                item.admission_date,
                item.discharge_date,
                item.diagnoses.joined(separator: " | "),
                item.medication.joined(separator: " | "),
                item.lab_values.joined(separator: " | "),
                item.discharge_status,
                item.warnings.joined(separator: " | "),
                String(format: "%.4f", item.confidence)
            ]
            rows.append(fields.map(csvEscaped).joined(separator: ","))
        }

        let bom = "\u{FEFF}"
        let body = rows.joined(separator: "\n") + "\n"
        let payload = bom + body
        try payload.write(to: outputFolder.appendingPathComponent("results.csv"), atomically: true, encoding: .utf8)
    }

    private func csvEscaped(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let escaped = normalized.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

// MARK: – Quick Look Preview Provider (macOS + iOS compatible)

/// Rich Quick Look preview for `*.spice-result.json` files. Renders a structured
/// table with the canonical fields (patient name, lab values list, diagnoses) so
/// the user can scan results in Finder without opening the app.
final class SHQuickLookPreview: QLPreviewProvider {

    // MARK: – macOS native preview API (macOS 10.15+)
    /// Native preview reply using `NSQuickLookPreviewReply` — renders HTML on the main thread.
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL

        return QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 720, height: 540)
        ) { _ in
            let data = try Data(contentsOf: url)
            return Self.htmlPreview(for: data).data(using: .utf8) ?? Data()
        }
    }

    // MARK: – HTML rendering
    /// Best-effort HTML rendering of an `SHExtractionResult`-shaped JSON.
    /// Keys we don't recognize are surfaced under a "Other fields" section
    /// so the preview never silently drops data.
    private static func htmlPreview(for data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return defaultHTML(title: "Spice Harvester result", body: "<p>Soubor není validní JSON.</p>")
        }

        var rows: [String] = []
        let canonicalKeys = [
            "patient_name", "patient_id", "birth_date",
            "admission_date", "discharge_date",
            "diagnoses", "medication", "lab_values",
            "discharge_status", "warnings", "confidence"
        ]
        for key in canonicalKeys where json[key] != nil {
            rows.append(rowHTML(key: key, value: json[key] ?? "—"))
        }
        let others = json.keys.filter { !canonicalKeys.contains($0) && $0 != "source_file" }.sorted()
        for key in others {
            rows.append(rowHTML(key: key, value: json[key] ?? "—"))
        }

        // `source_file` is user-controlled (filename of the source PDF),
        // so we MUST html-escape before injecting into <title> / <h1>.
        // Without this, a filename like `<script>...</script>.pdf`
        // executes from file:// origin in WebKit (XSS risk specific to
        // Quick Look previews).
        let rawTitle = (json["source_file"] as? String) ?? "Spice Harvester result"
        let safeTitle = escape(rawTitle)
        let body = "<table>\(rows.joined())</table>"
        return defaultHTML(title: safeTitle, body: body)
    }

    private static func rowHTML(key: String, value: Any) -> String {
        let formatted: String
        switch value {
        case let arr as [Any]:
            let items = arr.map { "<li>\(escape("\($0)"))</li>" }.joined()
            formatted = "<ul>\(items)</ul>"
        case let dict as [String: Any]:
            let inner = dict.map { "<b>\(escape($0.key))</b>: \(escape("\($0.value)"))" }.joined(separator: ", ")
            formatted = inner
        default:
            formatted = escape("\(value)")
        }
        return "<tr><th>\(escape(key))</th><td>\(formatted)</td></tr>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func defaultHTML(title: String, body: String) -> String {
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>
        body{font:13px -apple-system,system-ui;margin:18px;color:#222}
        h1{font-size:16px;margin:0 0 12px;color:#444}
        table{width:100%;border-collapse:collapse}
        th,td{padding:6px 8px;border-bottom:1px solid #eee;vertical-align:top;text-align:left}
        th{width:32%;color:#666;font-weight:500}
        ul{margin:0;padding-left:18px}
        @media (prefers-color-scheme:dark){
          body{background:#1e1e1e;color:#ddd}
          h1{color:#bbb}
          th{color:#888}
          th,td{border-color:#333}
        }
        </style></head>
        <body><h1>\(title)</h1>\(body)</body></html>
        """
    }
}
