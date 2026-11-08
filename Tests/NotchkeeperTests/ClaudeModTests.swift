import Foundation
import Testing
@testable import Notchkeeper

/// Output from `claude plugin list --json` (empirically tested on 2.1.296, keeping only used fields).
private func list(_ entries: [(id: String, enabled: Bool)]) -> Data {
    try! JSONSerialization.data(withJSONObject: entries.map { ["id": $0.id, "version": "1.0.0", "scope": "user", "enabled": $0.enabled] })
}

@Suite struct ClaudeModStatus {
    @Test func installedWhenListedAndEnabled() throws {
        #expect(try ClaudeMod.status(fromList: list([("swift-lsp@claude-plugins-official", true), ("pip@notifier", true)])) == .installed)
    }

    @Test func disabledWhenListedButOff() throws {
        #expect(try ClaudeMod.status(fromList: list([("pip@notifier", false)])) == .disabled)
    }

    @Test func notInstalledWhenAbsent() throws {
        #expect(try ClaudeMod.status(fromList: list([("swift-lsp@claude-plugins-official", true)])) == .notInstalled)
        #expect(try ClaudeMod.status(fromList: list([])) == .notInstalled)
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) { try ClaudeMod.status(fromList: Data("Error: not logged in".utf8)) }
    }
}
