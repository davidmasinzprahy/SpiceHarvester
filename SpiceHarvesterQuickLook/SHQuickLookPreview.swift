import Cocoa
import QuickLookUI

/// Rich Quick Look preview for `*.spice-result.json` files. Default JSON
/// preview shows raw text; this provider renders a structured table with
/// the canonical fields (patient name, lab values list, diagnoses) so
/// the user can scan results in Finder without opening the app.
final class SHQuickLookPreview: QLPreviewProvider, QLPreviewingController {

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
        // Without this, a filename like `evil<script>...</script>.pdf`
        // executes from file:// origin in WebKit (XSS risk specific to
        // Quick Look previews).
        let rawTitle = (json["source_file"] as? String) ?? "Spice Harvester result"
        let body = "<table>\(rows.joined())</table>"
        return defaultHTML(title: rawTitle, body: body)
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
        // Escape title at every injection point. Body is built up of
        // already-escaped row fragments (see `rowHTML`), so it doesn't
        // get re-escaped here — escaping pre-escaped content would
        // produce visible `&amp;lt;` instead of `<`.
        let safeTitle = escape(title)
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(safeTitle)</title>
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
        <body><h1>\(safeTitle)</h1>\(body)</body></html>
        """
    }
}
