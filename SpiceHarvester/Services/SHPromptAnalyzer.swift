import Foundation

/// Heuristic analyzer that inspects the user's prompt text and flags obvious
/// mismatches against the currently selected processing parameters.
///
/// The goal is not a perfect classifier – just to catch the common pattern where the
/// user describes "process everything together, return one JSON array" while the
/// pipeline is in FAST mode (per-document), or vice versa.
struct SHPromptAnalyzer: Sendable {
    /// Mode suggested by the prompt, plus a human-readable rationale. `nil` when no
    /// strong signal was detected – the current mode stays authoritative.
    struct ModeSuggestion: Equatable, Sendable {
        let mode: SHExtractionMode
        /// Short Czech explanation of why we think so (for the UI banner).
        let reason: String
    }

    /// Keywords that imply the prompt wants the **whole batch** processed in one
    /// request – CONSOLIDATE mode. Heavily weighted because mismatching this one
    /// produces the most confusing output (16 "arrays of 1" instead of 1 array of 16).
    private static let consolidateKeywords: [String] = [
        "celý vstup jako jeden",
        "jako jeden společný",
        "jako jeden datový",
        "celý batch",
        "celý vstup",
        "napříč soubory",
        "napříč dokumenty",
        "všech dokumentů dohromady",
        "nevytvářej odpověď po jednotlivých",
        "nevytvářej odpověď po souborech",
        "jediný json array",
        "jediný json",
        "jediné json pole",
        "jedno pole objektů",
        "konsoliduj",
        "konsolidova",
        "agreguj",
        "deduplikuj",
        "deduplikaci",
        "slouč údaje",
        "slouč do jednoho",
        "across all documents",
        "single json array",
        "one json array",
        "aggregate",
        "consolidate",
        "deduplicate",
    ]

    /// Keywords that imply per-document processing is desired explicitly.
    private static let fastKeywords: [String] = [
        "pro každý soubor",
        "pro každý dokument",
        "pro každou zprávu",
        "každý soubor samostatně",
        "každý dokument zvlášť",
        "per file",
        "per document",
        "one response per document",
    ]

    /// Keywords that imply RAG / semantic retrieval (SEARCH mode).
    private static let searchKeywords: [String] = [
        "semantic",
        "semanticky",
        "vyhledej relevantní",
        "najdi relevantní pasáže",
        "retrieval",
        "rag",
    ]

    static func suggestedMode(for prompt: String) -> ModeSuggestion? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.lowercased()

        if let hit = firstMatch(in: text, from: consolidateKeywords) {
            return ModeSuggestion(
                mode: .consolidate,
                reason: "Prompt obsahuje „\(hit)“ – míří na jeden společný výstup za celý batch."
            )
        }
        if let hit = firstMatch(in: text, from: fastKeywords) {
            return ModeSuggestion(
                mode: .fast,
                reason: "Prompt obsahuje „\(hit)“ – vyžaduje zpracování každého souboru zvlášť."
            )
        }
        if let hit = firstMatch(in: text, from: searchKeywords) {
            return ModeSuggestion(
                mode: .search,
                reason: "Prompt obsahuje „\(hit)“ – doporučeno sémantické vyhledávání přes embeddingy."
            )
        }
        return nil
    }

    private static func firstMatch(in haystack: String, from keywords: [String]) -> String? {
        for keyword in keywords where haystack.contains(keyword) {
            return keyword
        }
        return nil
    }
}

/// Structured conflict between the current config and the prompt's apparent intent.
/// Surfaced in the UI as a banner with an "Apply suggested" button.
enum SHParameterConflict: Equatable, Sendable {
    /// The prompt suggests a different extraction mode than is currently selected.
    case modeMismatch(current: SHExtractionMode, suggested: SHExtractionMode, reason: String)
    /// SEARCH mode is selected but no embedding model was picked – RAG will silently
    /// degrade to "top chunks" fallback, which the user probably didn't intend.
    case searchModeWithoutEmbeddingModel
    /// CONSOLIDATE mode with concurrency settings that are effectively ignored.
    /// Informational only – not actionable.
    case consolidateIgnoresConcurrency

    /// Short title for the banner.
    var title: String {
        switch self {
        case .modeMismatch(_, let suggested, _):
            return "Doporučený režim: \(suggested.title)"
        case .searchModeWithoutEmbeddingModel:
            return "SEARCH režim bez embedding modelu"
        case .consolidateIgnoresConcurrency:
            return "CONSOLIDATE zpracuje batch společně"
        }
    }

    /// Longer explanation.
    var message: String {
        switch self {
        case .modeMismatch(let current, let suggested, let reason):
            if suggested == .consolidate {
                return "\(reason) Přínos: model vidí všechny dokumenty ve stejném kontextu, takže může sloučit duplicity a vrátit jeden JSON napříč soubory místo samostatných odpovědí. Aktuálně je nastaveno \(current.title), doporučen \(suggested.title)."
            }
            return "\(reason) Aktuálně je nastaveno \(current.title), doporučen \(suggested.title)."
        case .searchModeWithoutEmbeddingModel:
            return "V režimu SEARCH pipeline potřebuje embedding model pro sémantické vyhledávání. Bez něj se použije pouze prvních pár chunků – RAG nebude fungovat."
        case .consolidateIgnoresConcurrency:
            return "Přínos je jeden společný výstup přes celý batch: model může porovnat dokumenty mezi sebou, sloučit duplicity a vrátit jeden JSON. Protože nejde o per-dokument běh, „Inference workers“ a „Throttle“ nemají efekt."
        }
    }

    /// Label for the action button; `nil` when the conflict is informational only.
    var actionLabel: String? {
        switch self {
        case .modeMismatch(_, let suggested, _):
            return "Přepnout na \(suggested.title)"
        case .searchModeWithoutEmbeddingModel:
            return "Přepnout na FAST"
        case .consolidateIgnoresConcurrency:
            return nil
        }
    }
}
