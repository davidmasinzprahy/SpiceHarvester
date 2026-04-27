import Foundation

struct SHPromptLibraryService {
    enum LoadError: Error, LocalizedError {
        case folderNotAccessible(String)
        case notADirectory(String)
        case fileNotFound(String)

        var errorDescription: String? {
            switch self {
            case .folderNotAccessible(let path):
                return "Složku nelze otevřít: \(path). Zkontroluj oprávnění (re-výběr složky)."
            case .notADirectory(let path):
                return "Cesta není složka: \(path)"
            case .fileNotFound(let path):
                return "Soubor neexistuje: \(path)"
            }
        }
    }

    /// Lists all `.md` files inside the folder, sorted by name.
    /// Caller is responsible for security-scoped access to the folder.
    func listFiles(in folder: URL) throws -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) else {
            throw LoadError.folderNotAccessible(folder.path)
        }
        guard isDir.boolValue else {
            throw LoadError.notADirectory(folder.path)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw LoadError.folderNotAccessible(folder.path)
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "md" {
            urls.append(fileURL)
        }
        return urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Returns the contents of a `.md` file. Caller is responsible for security scope.
    func loadContent(of fileURL: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LoadError.fileNotFound(fileURL.path)
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
