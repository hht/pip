import Foundation
import Testing
@testable import FirewallCore

@Suite struct StateFileFormat {
    @Test func roundTripsEveryShape() throws {
        var trial = FirewallState(bootSession: boot)
        try trial.enable(at: at(100))
        trial.record(.load(FirewallRules(tunnel: "utun1024", directory: "/nk")!))
        trial.record(.enable, token: "1864012227745836441")
        var on = trial
        try on.keep(at: at(110))
        on.record(.enable, token: nil)
        _ = on.check(mainRules: "", anchorRules: "pass all\n  [ Evaluations: 7055 ]\n", info: "", interfaces: "", tunnel: "utun1024")
        #expect(on.lastEvaluations == 7055)
        for s in [FirewallState(bootSession: boot), FirewallState(bootSession: nil), trial, on] {
            #expect(try FirewallState.restore(from: s.encoded()) == .valid(s))
        }
    }

    /// Rescue script reads token and bootSession using plutil -extract <key> raw: verify using actual plutil
    @Test func rescueScriptCanReadTokenAndBootSession() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        s.record(.enable, token: "18446744073709551615")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("firewall-\(UUID().uuidString).state")
        try s.encoded().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try plutilExtract("token", url) == "18446744073709551615")
        #expect(try plutilExtract("bootSession", url) == boot)
    }

    @Test func missingFileIsMissing() { #expect(FirewallState.restore(from: nil) == .missing) }

    /// Missing fields default to off: empty JSON means off with unknown boot session (handled as new boot next round)
    @Test func missingFieldsDefaultToOff() {
        #expect(FirewallState.restore(from: Data("{}".utf8)) == .valid(FirewallState(bootSession: nil)))
    }

    /// Unknown boot session omits this field: rescue script cannot read it, so will not compare against current boot session
    @Test func unknownBootSessionIsOmitted() throws {
        let json = try JSONSerialization.jsonObject(with: FirewallState(bootSession: nil).encoded()) as? [String: Any]
        #expect(json?["bootSession"] == nil)
    }

    @Test(arguments: [
        "not json",
        #"{"mode":"trial","bootSession":"B"}"#, // Trial without deadline
        #"{"mode":"armed","bootSession":"B"}"#,
        #"{"mode":"on","bootSession":"B","token":"12ab"}"#,
        #"{"mode":"on","bootSession":"B","token":""}"#,
        #"{"mode":"on","bootSession":"B","token":"12","tokenUnknown":true}"#,
    ])
    func malformedIsUnreadable(_ json: String) {
        #expect(FirewallState.restore(from: Data(json.utf8)) == .unreadable)
    }
}

private func plutilExtract(_ key: String, _ url: URL) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    p.arguments = ["-extract", key, "raw", "-o", "-", url.path]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
}
