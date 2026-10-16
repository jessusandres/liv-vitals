import Foundation

/// Carries progress callbacks from any thread to a main-actor handler, in order.
///
/// A service calls `send` from wherever its work runs; the handler runs on the main actor. Only the
/// newest pending value is kept, so a slow UI never falls behind a fast scan. Call `finish` when done.
nonisolated final class ProgressRelay<Value: Sendable>: Sendable {
    private let continuation: AsyncStream<Value>.Continuation
    private let consumer: Task<Void, Never>

    init(_ handler: @escaping @MainActor (Value) -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        consumer = Task { @MainActor in
            for await value in stream { handler(value) }
        }
    }

    @Sendable func send(_ value: Value) {
        continuation.yield(value)
    }

    /// Stops delivering; values already queued are still handled.
    func finish() {
        continuation.finish()
    }
}
