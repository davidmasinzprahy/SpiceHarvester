import Foundation

/// Generates minimal XLSX files (Open XML Spreadsheet) using only Foundation.
/// No external dependencies — builds a ZIP archive with the required XML parts.
enum XLSXWriter {

    struct Row {
        let cells: [String]
    }

    /// Writes an XLSX file with a single sheet to the given URL.
    /// - Parameters:
    ///   - rows: Array of rows; the first row is used as the header.
    ///   - sheetName: Name of the worksheet tab.
    ///   - url: Destination file URL.
    static func write(rows: [Row], sheetName: String = "Sheet1", to url: URL) throws {
        // Collect all unique strings for the shared strings table.
        var sharedStrings: [String] = []
        var stringIndex: [String: Int] = [:]

        func registerString(_ s: String) -> Int {
            if let idx = stringIndex[s] { return idx }
            let idx = sharedStrings.count
            sharedStrings.append(s)
            stringIndex[s] = idx
            return idx
        }

        // Pre-register all cell values.
        for row in rows {
            for cell in row.cells {
                _ = registerString(cell)
            }
        }

        // Build XML parts.
        let contentTypes = buildContentTypes()
        let rels = buildRels()
        let workbook = buildWorkbook(sheetName: sheetName)
        let workbookRels = buildWorkbookRels()
        let styles = buildStyles()
        let sharedStringsXML = buildSharedStrings(sharedStrings)
        let sheetXML = buildSheet(rows: rows, stringIndex: stringIndex)

        // Create a temporary directory for assembly.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write XML files into the temp directory structure.
        let files: [(String, String)] = [
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", rels),
            ("xl/workbook.xml", workbook),
            ("xl/_rels/workbook.xml.rels", workbookRels),
            ("xl/styles.xml", styles),
            ("xl/sharedStrings.xml", sharedStringsXML),
            ("xl/worksheets/sheet1.xml", sheetXML),
        ]

        for (path, content) in files {
            let fileURL = tempDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        // Create ZIP archive using /usr/bin/ditto (available on all macOS).
        try? FileManager.default.removeItem(at: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", tempDir.path, url.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw XLSXError.zipFailed
        }
    }

    enum XLSXError: LocalizedError {
        case zipFailed

        var errorDescription: String? {
            "Nepodařilo se vytvořit XLSX soubor."
        }
    }

    // MARK: - XML Builders

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func columnLetter(_ index: Int) -> String {
        var result = ""
        var n = index
        while true {
            result = String(UnicodeScalar(65 + (n % 26))!) + result
            n = n / 26 - 1
            if n < 0 { break }
        }
        return result
    }

    private static func buildContentTypes() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
          <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
        </Types>
        """
    }

    private static func buildRels() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
    }

    private static func buildWorkbook(sheetName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="\(xmlEscape(sheetName))" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """
    }

    private static func buildWorkbookRels() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        </Relationships>
        """
    }

    private static func buildStyles() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="2">
            <font><sz val="11"/><name val="Calibri"/></font>
            <font><b/><sz val="11"/><name val="Calibri"/></font>
          </fonts>
          <fills count="2">
            <fill><patternFill patternType="none"/></fill>
            <fill><patternFill patternType="gray125"/></fill>
          </fills>
          <borders count="1">
            <border><left/><right/><top/><bottom/><diagonal/></border>
          </borders>
          <cellStyleXfs count="1">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
          </cellStyleXfs>
          <cellXfs count="2">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
          </cellXfs>
        </styleSheet>
        """
    }

    private static func buildSharedStrings(_ strings: [String]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(strings.count)" uniqueCount="\(strings.count)">
        """

        for s in strings {
            // Use xml:space="preserve" to keep whitespace in cells.
            xml += "<si><t xml:space=\"preserve\">\(xmlEscape(s))</t></si>\n"
        }

        xml += "</sst>"
        return xml
    }

    private static func buildSheet(rows: [Row], stringIndex: [String: Int]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
        """

        for (rowIdx, row) in rows.enumerated() {
            let rowNum = rowIdx + 1
            // First row gets bold style (s="1")
            let isHeader = rowIdx == 0
            xml += "<row r=\"\(rowNum)\">"
            for (colIdx, cell) in row.cells.enumerated() {
                let col = columnLetter(colIdx)
                let ref = "\(col)\(rowNum)"
                let idx = stringIndex[cell] ?? 0
                let style = isHeader ? " s=\"1\"" : ""
                xml += "<c r=\"\(ref)\" t=\"s\"\(style)><v>\(idx)</v></c>"
            }
            xml += "</row>\n"
        }

        xml += """
          </sheetData>
        </worksheet>
        """
        return xml
    }
}
