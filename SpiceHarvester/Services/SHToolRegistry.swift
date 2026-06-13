import Foundation

actor SHToolRegistry {
    enum Status: Sendable, Equatable {
        case available(version: String)
        case missing
    }

    private let runtime: SHToolRuntime
    private var cache: [SHTool: Status] = [:]

    init(runtime: SHToolRuntime = SHToolRuntime()) {
        self.runtime = runtime
    }

    func status(for tool: SHTool) async -> Status {
        if let cached = cache[tool] { return cached }
        let resolved: Status
        if runtime.resolve(tool) == nil {
            resolved = .missing
        } else if let result = try? await runtime.run(tool, arguments: tool.versionArguments, timeout: 15),
                  result.exitCode == 0 {
            let merged = result.stdoutString + "\n" + result.stderrString
            resolved = .available(version: Self.parseVersion(from: merged) ?? "neznámá")
        } else {
            resolved = .missing
        }
        cache[tool] = resolved
        return resolved
    }

    /// Stabilní řetězec verzí pro cache signaturu. Změna verze nástroje invaliduje cache.
    func signatureComponent(for tools: [SHTool]) async -> String {
        var parts: [String] = []
        for tool in tools.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch await status(for: tool) {
            case .available(let version): parts.append("\(tool.rawValue)=\(version)")
            case .missing: parts.append("\(tool.rawValue)=missing")
            }
        }
        return parts.joined(separator: ";")
    }

    /// Čistá funkce: první výskyt `N.N` nebo `N.N.N` ve výstupu `--version`.
    static func parseVersion(from output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }
}
