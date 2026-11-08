import Foundation
import Testing
@testable import AgentCore

/// Constructed modeled after real session files observed (docs/agent-integration.md "Observations"), only mutating tested fields
private func file(_ overrides: [String: Any?] = [:]) -> Data {
    var json: [String: Any] = [
        "pid": 31301, "sessionId": "5d0c7c2e-0000-4000-8000-000000000000", "cwd": "/Users/u/Documents/Projects/pip",
        "startedAt": 1793296492153, "procStart": "Thu Oct 29 17:54:51 2026", "version": "2.1.296", "peerProtocol": 1,
        "kind": "interactive", "entrypoint": "cli", "pidDomain": "darwin", "name": "session name", "nameSource": "user",
        "status": "busy", "statusUpdatedAt": 1793304005799, "updatedAt": 1793304005799,
    ]
    for (k, v) in overrides { json[k] = v }
    return try! JSONSerialization.data(withJSONObject: json)
}

/// 2026-10-29 17:54:51 UTC
private let procStart = Date(timeIntervalSince1970: 1_793_296_491)

@Suite struct SessionFileParsing {
    @Test func busyCLISession() throws {
        #expect(try SessionFile.parse(file()) == Session(
            pid: 31301, processStart: procStart, sessionId: "5d0c7c2e-0000-4000-8000-000000000000",
            cwd: "/Users/u/Documents/Projects/pip",
            state: .working, stateSince: Date(timeIntervalSince1970: 1_793_304_005.799)))
    }
}

@Suite struct SessionStateMapping {
    private func state(_ status: String, waitingFor: String? = nil) throws -> AgentState? {
        try SessionFile.parse(file(["status": status, "waitingFor": waitingFor]))?.state
    }

    @Test func busyIsWorking() throws {
        #expect(try state("busy") == .working)
    }

    /// shell is idle, but background shell command is running (docs/agent-integration.md "Observations" 6)
    @Test func idleAndShellAreStopped() throws {
        #expect(try state("idle") == .stopped)
        #expect(try state("shell") == .stopped)
    }

    /// Per Claude Code's own taxonomy: first 4 are permissions (docs/agent-integration.md "Observations" 3)
    @Test(arguments: ["permission prompt", "sandbox request", "worker request", "goal proposal"])
    func permissionKindsNeedApproval(_ waitingFor: String) throws {
        #expect(try state("waiting", waitingFor: waitingFor) == .needsYou(.approval))
    }

    /// dialog open, unseen values, missing waitingFor: all still require intervention, categorized as question
    @Test(arguments: ["input needed", "dialog open", "something new", nil] as [String?])
    func otherWaitsAreQuestions(_ waitingFor: String?) throws {
        #expect(try state("waiting", waitingFor: waitingFor) == .needsYou(.question))
    }
}

/// Only targets interactive claude in terminal: claude -p has kind == "interactive" as well, distinguished by entrypoint
@Suite struct SessionFiltering {
    @Test(arguments: ["sdk-cli", "sdk-ts", "sdk-py", "claude-vscode", "claude-desktop", "remote"])
    func otherEntrypointsAreIgnored(_ entrypoint: String) throws {
        #expect(try SessionFile.parse(file(["entrypoint": entrypoint])) == nil)
    }

    @Test(arguments: ["bg", "daemon", "daemon-worker"])
    func otherKindsAreIgnored(_ kind: String) throws {
        #expect(try SessionFile.parse(file(["kind": kind])) == nil)
    }

    /// Initial file written upon startup lacks status and statusUpdatedAt, filled in shortly after (observed): lacks status, skipped temporarily without error
    @Test func sessionWithoutStatusYetIsIgnored() throws {
        #expect(try SessionFile.parse(file(["status": nil, "statusUpdatedAt": nil, "updatedAt": nil])) == nil)
    }

    /// Ignored sessions are not validated: missing fields or unknown status do not fail parsing
    @Test func ignoredSessionIsNotValidated() throws {
        #expect(try SessionFile.parse(file(["entrypoint": "sdk-cli", "status": "bogus", "procStart": nil])) == nil)
    }
}

@Suite struct SessionFileBoundary {
    /// ps lstart pads single-digit day with space (%e)
    @Test func singleDigitDayIsSpacePadded() throws {
        let s = try SessionFile.parse(file(["procStart": "Mon Nov  2 03:04:05 2026"]))
        #expect(s?.processStart == Date(timeIntervalSince1970: 1_793_588_645)) // 2026-11-02T03:04:05Z
    }

    @Test(arguments: ["", "Thu Oct 29 2026", "2026-10-29T17:54:51Z"])
    func badProcStartThrows(_ text: String) {
        #expect(throws: (any Error).self) { try SessionFile.parse(file(["procStart": text])) }
    }

    /// sessionId is interpolated into turn file path: non-UUID is strictly rejected (CLAUDE.md Principle 5)
    @Test func sessionIdMustBeUUID() {
        #expect(throws: SessionFileError.badSessionId("../../config")) { try SessionFile.parse(file(["sessionId": "../../config"])) }
    }

    @Test func unknownStatusThrows() {
        #expect(throws: SessionFileError.unknownStatus("thinking")) { try SessionFile.parse(file(["status": "thinking"])) }
    }

    @Test(arguments: ["pid", "procStart", "sessionId", "cwd", "statusUpdatedAt"])
    func missingFieldThrows(_ key: String) {
        #expect(throws: (any Error).self) { try SessionFile.parse(file([key: nil])) }
    }

    /// Partially written file
    @Test func truncatedJSONThrows() {
        #expect(throws: (any Error).self) { try SessionFile.parse(Data(#"{"pid":1,"kind":"interactive""#.utf8)) }
    }
}
