import Foundation

struct SHToolRuntime: Sendable {
    let helpersDirectory: URL?
    let pathDirectories: [URL]

    init(
        helpersDirectory: URL? = SHToolRuntime.defaultHelpersDirectory,
        pathDirectories: [URL] = SHToolRuntime.defaultPathDirectories
    ) {
        self.helpersDirectory = helpersDirectory
        self.pathDirectories = pathDirectories
    }

    /// Bundlovaná binárka má přednost před PATH (PATH je jen vývojová pohodlnost).
    func resolve(_ tool: SHTool) -> URL? {
        let fm = FileManager.default
        if let helpers = helpersDirectory {
            let candidate = helpers.appendingPathComponent(tool.executableName)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        for dir in pathDirectories {
            let candidate = dir.appendingPathComponent(tool.executableName)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static var defaultHelpersDirectory: URL? {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    static var defaultPathDirectories: [URL] {
        let raw = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return raw.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    func run(
        _ tool: SHTool,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 120
    ) async throws -> SHToolResult {
        guard let executable = resolve(tool) else { throw SHToolError.notFound(tool) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Vstupní rouru alokuj jen když opravdu posíláme stdin (jinak zbytečné FD).
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SHToolResult, Error>) in
                // Souběžné vyčerpávání rour na pozadí: bez toho by dítě, které zapíše
                // víc než ~64 KB na stdout dřív, než skončí, zaplnilo buffer roury,
                // zablokovalo se na write() a nikdy by nespustilo terminationHandler
                // (deadlock při velkém výstupu pdftotext/pandoc).
                let ioGroup = DispatchGroup()
                let lock = NSLock()
                var outData = Data()
                var errData = Data()

                ioGroup.enter()
                DispatchQueue.global().async {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); outData = data; lock.unlock()
                    ioGroup.leave()
                }
                ioGroup.enter()
                DispatchQueue.global().async {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); errData = data; lock.unlock()
                    ioGroup.leave()
                }

                let timeoutItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                process.terminationHandler = { proc in
                    timeoutItem.cancel()
                    // Počkej, až obě roury dočtou EOF (dítě zavřelo write konce při exitu),
                    // teprve pak resume — zaručí kompletní stdout/stderr i u velkého výstupu.
                    ioGroup.notify(queue: DispatchQueue.global()) {
                        lock.lock(); let out = outData; let err = errData; lock.unlock()
                        if proc.terminationReason == .uncaughtSignal {
                            continuation.resume(throwing: SHToolError.timedOut(tool))
                        } else {
                            continuation.resume(returning: SHToolResult(exitCode: proc.terminationStatus, stdout: out, stderr: err))
                        }
                    }
                }

                do {
                    try process.run()
                    if let stdin, let inPipe {
                        inPipe.fileHandleForWriting.write(stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }
                } catch {
                    timeoutItem.cancel()
                    // Uvolni drain vlákna: bez zavření write konců by readDataToEndOfFile čekalo navždy.
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // Zrušení Swift tasku ukončí proces; terminationHandler pak resume continuation.
            if process.isRunning { process.terminate() }
        }
    }
}
