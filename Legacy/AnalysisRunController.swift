import SwiftUI

final class AnalysisRunController: @unchecked Sendable {
    private let lock = NSLock()
    private var activeTasks: [UUID: URLSessionTask] = [:]
    private var activeStreams: [UUID: LMStudioStreamHandler] = [:]

    func startNewRun() {
        lock.lock()
        activeTasks.removeAll()
        activeStreams.removeAll()
        lock.unlock()
    }

    func cancel() {
        let tasks: [URLSessionTask]
        let streams: [LMStudioStreamHandler]

        lock.lock()
        tasks = Array(activeTasks.values)
        streams = Array(activeStreams.values)
        activeTasks.removeAll()
        activeStreams.removeAll()
        lock.unlock()

        tasks.forEach { $0.cancel() }
        streams.forEach { $0.cancel() }
    }

    func register(task: URLSessionTask, id: UUID) {
        lock.lock()
        activeTasks[id] = task
        lock.unlock()
    }

    func unregisterTask(id: UUID) {
        lock.lock()
        activeTasks.removeValue(forKey: id)
        lock.unlock()
    }

    func cancelTask(id: UUID) {
        lock.lock()
        let task = activeTasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    func register(stream: LMStudioStreamHandler, id: UUID) {
        lock.lock()
        activeStreams[id] = stream
        lock.unlock()
    }

    func unregisterStream(id: UUID) {
        lock.lock()
        activeStreams.removeValue(forKey: id)
        lock.unlock()
    }
}

enum DiagnosticTone {
    case ok
    case warning
    case error
    case neutral
}

struct DiagnosticItem {
    let title: String
    let value: String
    let tone: DiagnosticTone
}

struct InputContextEstimate {
    let title: String
    let estimatedTokens: Int
    let extractedCharacters: Int
    let fileCount: Int
    let estimatedChunkCount: Int
    let extractionWarning: String?
    let dominantExtension: String
}

struct ModelRuntimeInfo {
    let loaded: Int?
    let max: Int?
    let type: String?
    let state: String?
}

struct ModelListResult {
    let snapshot: ModelSnapshot?
    let allModelIDs: [String]
}

final class AtomicBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        lock.lock()
        let v = _value
        lock.unlock()
        return v
    }

    func set(_ newValue: Bool) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }
}

final class SharedTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: TimeInterval

    init(_ value: TimeInterval) {
        _value = value
    }

    var value: TimeInterval {
        lock.lock()
        let v = _value
        lock.unlock()
        return v
    }

    func set(_ newValue: TimeInterval) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }
}
