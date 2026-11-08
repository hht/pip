import Foundation
import Testing
@testable import GuardProbes

/// Route probe child process: each round has an 8s deadline; when cancelled on timeout, the child process must be terminated so it doesn't hold up a round.
@Suite struct SubprocessOutput {
    private let clock = ContinuousClock()

    @Test func returnsStdout() async {
        #expect(await RouteProbe.output(of: URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"]) == "hi\n")
    }

    @Test func nonZeroExitIsNil() async {
        #expect(await RouteProbe.output(of: URL(fileURLWithPath: "/usr/bin/false"), arguments: []) == nil)
    }

    @Test func cancelTerminatesChild() async {
        let begin = clock.now
        let task = Task { await RouteProbe.output(of: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        #expect(await task.value == nil)
        #expect(clock.now - begin < .seconds(2))
    }

    /// Tasks that are already cancelled do not launch a child process
    @Test func cancelledBeforeLaunchNeverRuns() async {
        let begin = clock.now
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RouteProbe.output(of: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        }
        #expect(await task.value == nil)
        #expect(clock.now - begin < .seconds(1))
    }
}
