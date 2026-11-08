import Foundation
import Testing
@testable import AgentCore

private let sessionId = "688a6655-4344-485c-a13d-7770659b1c4f"

/// Constructed modeled after mod-written files (docs/agent-integration.md "Turn files"), only mutating tested fields in ended
private func file(_ overrides: [String: Any?] = [:], sessionId: Any? = sessionId) -> Data {
    var ended: [String: Any] = ["turnId": "t1", "reason": "answer", "lastStop": "end_turn", "backgroundAgents": 0, "at": 1_793_349_276_766]
    for (k, v) in overrides { ended[k] = v }
    var json: [String: Any] = ["ended": ended]
    json["sessionId"] = sessionId
    return try! JSONSerialization.data(withJSONObject: json)
}

/// Table in docs/agent-integration.md "How turns end"
@Suite struct TurnOutcomes {
    private func outcome(_ overrides: [String: Any?]) throws -> TurnOutcome? {
        try TurnFile.parse(file(overrides)).ended?.outcome
    }

    @Test(arguments: ["end_turn", "max_tokens", "stop_sequence", nil] as [String?])
    func answerIsDone(_ lastStop: String?) throws {
        #expect(try outcome(["lastStop": lastStop]) == .done)
    }

    /// Rejected in approval prompt: reason is still answer, lastStep stopped at tool_use (observed)
    @Test func answerStoppedAtToolUseIsCanceled() throws {
        #expect(try outcome(["lastStop": "tool_use"]) == .canceled)
    }

    @Test func abortedIsCanceled() throws {
        #expect(try outcome(["reason": "aborted", "lastStop": nil]) == .canceled)
    }

    @Test(arguments: ["error", "refusal"])
    func errorAndRefusalFail(_ reason: String) throws {
        #expect(try outcome(["reason": reason, "lastStop": nil]) == .failed)
    }
}

@Suite struct TurnFileParsing {
    @Test func endedTurn() throws {
        #expect(try TurnFile.parse(file(["backgroundAgents": 2])) == TurnReport(
            sessionId: sessionId,
            ended: EndedTurn(turnId: "t1", outcome: .done, backgroundAgents: 2, at: Date(timeIntervalSince1970: 1_793_349_276.766))))
    }

    /// When a session after /clear has not ended any turn, mod omits it; parsed identically if written as null
    @Test func noEndedTurn() throws {
        let data = try JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "ended": NSNull()])
        #expect(try TurnFile.parse(data) == TurnReport(sessionId: sessionId, ended: nil))
    }

    @Test func unknownReasonThrows() {
        #expect(throws: TurnFileError.unknownReason("timeout")) { try TurnFile.parse(file(["reason": "timeout"])) }
    }

    /// sessionId is interpolated into file path to delete: non-UUID is strictly rejected (CLAUDE.md Principle 5)
    @Test(arguments: ["../../config", "", "s1"])
    func sessionIdMustBeUUID(_ id: String) {
        #expect(throws: TurnFileError.badSessionId(id)) { try TurnFile.parse(file(sessionId: id)) }
    }

    @Test(arguments: ["turnId", "reason", "backgroundAgents", "at"])
    func missingFieldThrows(_ key: String) {
        #expect(throws: (any Error).self) { try TurnFile.parse(file([key: nil])) }
    }

    /// $.fs.write is not atomic: partially written data
    @Test func truncatedJSONThrows() {
        #expect(throws: (any Error).self) { try TurnFile.parse(Data(#"{"sessionId":"s1","ende"#.utf8)) }
    }
}
