import Foundation

/// FIFO-ordered async semaphore, cancellation-safe.
///
/// Fixes:
/// - `waiters` is an array (FIFO), not a dictionary, so there is no starvation.
/// - Cancellation is installed **before** the continuation is registered and clears
///   the exact continuation if cancelled between registration and resume.
/// - `signal()` resumes the oldest waiter deterministically.
actor SHAsyncSemaphore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var value: Int
    private var waiters: [Waiter] = []

    init(value: Int) {
        self.value = max(1, value)
    }

    func wait() async throws {
        try Task.checkCancellation()
        if value > 0 {
            value -= 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func signal() {
        if !waiters.isEmpty {
            let first = waiters.removeFirst()
            first.continuation.resume()
        } else {
            value += 1
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

actor SHQueueManager {
    private let semaphore: SHAsyncSemaphore

    init(maxConcurrent: Int) {
        self.semaphore = SHAsyncSemaphore(value: maxConcurrent)
    }

    /// Runs `operation` while holding one slot. Guarantees the slot is released on every
    /// exit path – success, throwing, or task cancellation – via a deferred signal.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await semaphore.wait()
        // Slot is held. `defer` captures `semaphore` by reference (actor) and guarantees
        // a signal on any return path, including cancellation propagation out of this
        // suspension region.
        defer {
            Task { [semaphore] in await semaphore.signal() }
        }
        return try await operation()
    }
}
