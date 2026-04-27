import Foundation

/// Strips boilerplate from PDF-extracted text so that the LLM gets a dense,
/// signal-rich input. Every line removed here saves tokens in the prompt and –
/// because attention is O(n²) – compounds into measurable inference speedup.
///
/// Focused on Czech medical discharge summaries: hospital letterheads,
/// department contacts, physician signature blocks, audit trail lines
/// ("vytištěno dne", "č.j."), and purely decorative rules / ornaments from OCR.
///
/// Deliberately conservative: we never strip clinical content (diagnoses,
/// medications, labs, dates), only typographic frames and administrative
/// metadata that has no bearing on the extraction task.
struct SHTextCleaningService {
    /// Bump whenever the cleaning logic changes (new/adjusted classifiers).
    /// Included in downstream cache keys so a cleaner change invalidates stale
    /// inference responses that were produced from a differently-cleaned text.
    static let version = "v2"

    func cleanPages(_ pages: [String]) -> [SHDocumentPage] {
        guard !pages.isEmpty else { return [] }

        let linePages = pages.map { normalizedLines(in: $0) }
        let repeatedHeaderCandidates = repeatingTopBottomLines(linePages: linePages, top: true)
        let repeatedFooterCandidates = repeatingTopBottomLines(linePages: linePages, top: false)

        return linePages.enumerated().map { index, lines in
            let filtered = lines.filter { line in
                let normalized = line.lowercased()
                return !repeatedHeaderCandidates.contains(normalized)
                    && !repeatedFooterCandidates.contains(normalized)
                    && !isPageNumber(line)
                    && !isSignatureLine(line)
                    && !isVisualNoise(line)
                    && !isContactOrAddress(line)
                    && !isAuditTrail(line)
                    && !isOCRGlyphNoise(line)
                    && !isHorizontalRule(line)
            }

            let cleaned = filtered.joined(separator: "\n")
            return SHDocumentPage(pageIndex: index, rawText: pages[index], cleanedText: cleaned)
        }
    }

    private func normalizedLines(in text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func repeatingTopBottomLines(linePages: [[String]], top: Bool) -> Set<String> {
        var counts: [String: Int] = [:]
        for lines in linePages {
            let probe = top ? Array(lines.prefix(6)) : Array(lines.suffix(6))
            for line in probe {
                let key = line.lowercased()
                counts[key, default: 0] += 1
            }
        }

        let threshold = max(2, Int(Double(linePages.count) * 0.45))
        return Set(counts.compactMap { key, value in
            value >= threshold ? key : nil
        })
    }

    // MARK: – Per-line classifiers

    private func isPageNumber(_ line: String) -> Bool {
        let lowercase = line.lowercased()
        let patterns = [
            #"^strana\s+\d+"#,
            #"^stránka\s+\d+"#,
            #"^str\.\s*\d+"#,
            #"^page\s+\d+"#,
            #"^\d+\s*/\s*\d+$"#,
            #"^\d+\s+z\s+\d+$"#,       // "3 z 5"
            #"^\d+\s+of\s+\d+$"#,
            #"^-\s*\d+\s*-$"#,         // "- 3 -"
            #"^\d+$"#
        ]
        for pattern in patterns where lowercase.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Signature lines are positional (end of block), formally opened with a title
    /// or label. We anchor patterns to the **start** of the line so free-text
    /// mentions like "kontrolu u praktického lékaře" / "předáno MUDr. Novákovi"
    /// stay intact – both carry clinical next-step information.
    private func isSignatureLine(_ line: String) -> Bool {
        let lowered = line.lowercased()

        // Line-start markers. Czech medical signatures virtually always begin
        // with one of these title / label tokens.
        let startPrefixes = [
            "mudr.", "mudr ",
            "prim.", "prim ", "primář",
            "doc.", "doc ",
            "prof.", "prof ",
            "podpis:", "podpis ",
            "razítko:", "razítko ",
            "vypracoval", "vypracovala",
            "provedl", "provedla",
            "zapsal", "zapsala",
            "ověřil", "ověřila", "overil",
            "kontroloval", "kontrolovala",
            "podepsán", "podepsáno",
            "vedoucí lékař", "vedouci lekar",
            "ošetřující lékař", "osetrujici lekar",
            "atestovaný lékař",
        ]
        if startPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }

        // Short standalone credential suffix lines (e.g. "Jan Novák, Ph.D., CSc.").
        // Keep the short-line guard to avoid stripping a paragraph that just
        // happens to mention credentials in running text.
        if line.count < 80 {
            let credentialMarkers = ["ph.d.", "ph. d.", "csc.", "dr.sc."]
            if credentialMarkers.contains(where: { lowered.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Visual noise = letterhead branding, URLs, and decorative department labels
    /// that aren't clinical content. Anchored to line start so sentences that
    /// mention e.g. "přeložen z Fakultní nemocnice Brno" (clinically relevant
    /// provenance) or "přijat na oddělení kardiologie" (care context) pass through.
    private func isVisualNoise(_ line: String) -> Bool {
        let lowered = line.lowercased()

        // Anchored brand / URL strings
        let prefixes = [
            "logo ", "logo:",
            "www.", "http://", "https://",
            "fakultní nemocnice", "fakultni nemocnice",
            "nemocnice ", "hospital ",
        ]
        if prefixes.contains(where: { lowered.hasPrefix($0) }) { return true }

        // Letterhead-style short department labels: line STARTS with the label
        // and is a standalone (no sentence structure).
        if line.count < 32 {
            let deptPrefixes = ["oddělení ", "oddělení:", "klinika ", "klinika:",
                                "ambulance ", "ambulance:"]
            if deptPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// Contact info and postal addresses: phone/fax/email/web plus Czech PSČ
    /// patterns and IČO/IČZ/IČP identifiers, which never carry clinical signal.
    /// All patterns anchored so that sentence fragments containing e.g. numeric
    /// measurements ("v Brně 10 340 cells/µl") don't trigger.
    private func isContactOrAddress(_ line: String) -> Bool {
        let lowered = line.lowercased()

        // Phone / fax / email / web prefixes — already anchored, safe.
        let contactPrefixes = ["tel:", "tel.:", "telefon:", "fax:", "fax.:",
                               "e-mail:", "email:", "mail:"]
        if contactPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }

        // Email-only lines: require the whole line to look like an email address
        // (no surrounding prose), not just "text contains @ and .".
        if line.count < 60,
           line.range(of: #"^\s*\S+@\S+\.\S+\s*$"#, options: .regularExpression) != nil {
            return true
        }

        // Institution / billing IDs (IČO/IČZ/IČP/DIČ) — prefix anchor.
        let idPrefixes = ["ičo:", "ičo ", "ičz:", "ičz ", "ičp:", "ičp ", "dič:", "dič "]
        if idPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }

        // Czech postal code "NNN NN" must appear AT THE START of the line
        // (typical address: "110 00 Praha 1, Ulice X"). A postal code hiding
        // inside a clinical sentence ("leukocytů 10 340 /µl") won't match.
        if line.range(of: #"^\s*\d{3}\s?\d{2}\s+\S"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    /// Administrative audit-trail lines: print timestamps, case numbers, form IDs.
    private func isAuditTrail(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let markers = [
            "vytištěno dne", "vytisteno dne",
            "vystaveno dne",
            "datum tisku", "datum vyhotovení", "datum vyhotoveni",
            "č.j.:", "č. j.:", "c.j.:", "cj:",
            "spisová značka", "spisova znacka",
            "formulář č.", "formular c.",
            "verze dokumentu", "verze formuláře",
            "copyright", "©",
            "všechna práva vyhrazena",
        ]
        return markers.contains(where: { lowered.contains($0) })
    }

    /// OCR artefacts that aren't words: mostly-punctuation lines, box-drawing
    /// characters, underscores used as visual rules. Preserves legitimate short
    /// lines like lab-value shorthand ("CRP 4", "Hb 135").
    private func isOCRGlyphNoise(_ line: String) -> Bool {
        guard !line.isEmpty else { return true }
        let letterCount = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digitCount = line.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let meaningful = letterCount + digitCount
        // If the line has almost no letters/digits, it's likely a decorative rule.
        if line.count >= 3 && Double(meaningful) / Double(line.count) < 0.25 {
            return true
        }
        return false
    }

    /// Pure horizontal separators: "====", "----", "____", "****".
    private func isHorizontalRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let ruleChars: Set<Character> = ["=", "-", "_", "*", "─", "━", "·", "•", "°"]
        return line.allSatisfy { ruleChars.contains($0) || $0 == " " }
    }
}
