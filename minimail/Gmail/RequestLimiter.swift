import Foundation

/// FIFO counting semaphore for in-flight HTTP requests (architecture §6.4: no token bucket, `max = 2`).
actor RequestLimiter {
    private let max: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `max` ≥ 1 (precondition).
    init(max: Int = 2) {
        precondition(max >= 1, "max must be ≥ 1")
        self.max = max
        self.available = max
    }

    /// Waits for a permit (FIFO), runs `op`, releases the permit whether `op` returns or throws.
    func withPermit<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await op()
    }

    /// Number of permits currently held (0…max).
    var inUse: Int { max - available }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            // Transfer the permit directly to the next waiter; `available` is not incremented.
            waiters.removeFirst().resume()
        } else {
            available += 1
        }
    }
}
