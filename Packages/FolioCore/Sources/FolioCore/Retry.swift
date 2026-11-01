import Foundation

/// Errors that know whether trying again could help.
public protocol RetryClassifiable: Error {
    var isTransient: Bool { get }
}

/// Exponential backoff with full jitter.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration

    public init(maxAttempts: Int = 3, baseDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(8)) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    /// Upper bound of the delay before attempt `attempt + 1` (attempt is 1-based).
    public func delayCeiling(afterAttempt attempt: Int) -> Duration {
        let factor = 1 << min(max(attempt - 1, 0), 16)
        let ceiling = baseDelay * factor
        return ceiling > maxDelay ? maxDelay : ceiling
    }

    /// Runs `operation`, retrying while the error is transient.
    public func run<T: Sendable>(
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as RetryClassifiable where error.isTransient && attempt < maxAttempts {
                let ceiling = delayCeiling(afterAttempt: attempt)
                let millis = ceiling.components.seconds * 1000 + ceiling.components.attoseconds / 1_000_000_000_000_000
                try await sleep(.milliseconds(Int64.random(in: 0...max(0, millis))))
                attempt += 1
            }
        }
    }
}

/// Clock abstraction so time-dependent logic can be tested.
public protocol FolioClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: FolioClock {
    public init() {}
    public var now: Date { Date() }
}
