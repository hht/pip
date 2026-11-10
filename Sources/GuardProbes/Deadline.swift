/// Answers: whether a block of asynchronous work finished before the deadline.
/// The work races against a sleep in a task group, and whichever arrives first determines the outcome;
/// timeouts return `nil` ("no result") and cancel the work.
/// The task group waits for all subtasks to terminate before returning, so cancelled work must respond to cancellation
/// (`URLSession` does; route child process relies on `RouteProbe.output` terminating on cancellation),
/// otherwise timeouts would also be held up by it.
/// Clock is injected via parameter.
/// @see https://developer.apple.com/documentation/swift/withtaskgroup(of:returning:isolation:body:)
enum Deadline {
    static func run<T: Sendable, C: Clock>(
        by deadline: C.Instant, clock: C, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await clock.sleep(until: deadline, tolerance: nil) // Being cancelled means work arrived first; return value unused
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
