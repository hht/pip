import Foundation
import Testing
import NotchCore
@testable import PluginCore
@testable import pipctl

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let id = UUID()

private func notify(_ args: [String]) throws -> Message {
    try Message.parse(Notify.message(args, id: id, now: t0))
}

@Suite struct NotifyArguments {
    @Test func minimal() throws {
        let m = try notify(["--plugin", "terminal", "--title", "sleep finished"])
        #expect(m.plugin == "terminal" && m.title == "sleep finished" && m.id == id && m.at == t0)
        #expect(m.outcome == .info)
        #expect(m.subtitle == nil && m.value == nil && m.group == nil && m.block == nil && m.action == nil)
    }

    @Test func allOptions() throws {
        let m = try notify(["--plugin", "terminal", "--title", "sleep failed", "--subtitle", "~/x", "--value", "12s", "--outcome", "failed",
                            "--group", "tty:/dev/ttys003", "--fact", "exit_code=1", "--fact", "dir=~/a=b", "--open", "https://example.com/x"])
        #expect(m.subtitle == "~/x" && m.value == "12s" && m.outcome == .failed && m.group == "tty:/dev/ttys003")
        #expect(m.block == .facts([.init(title: "exit_code", value: "1"), .init(title: "dir", value: "~/a=b")]))
        #expect(m.action == .open(URL(string: "https://example.com/x")!))
    }

    /// zsh plugin passes `--tty $TTY --pid $$ --cwd $PWD`: clicking card returns focus to this terminal
    @Test func focusTerminal() throws {
        let m = try notify(["--plugin", "terminal", "--title", "x", "--tty", "/dev/ttys003", "--pid", "4242", "--cwd", "/Users/x"])
        #expect(m.action == .focusTerminal(tty: "/dev/ttys003", pid: 4242, cwd: "/Users/x"))
    }

    @Test(arguments: [["--tty", "/dev/ttys003"], ["--tty", "/dev/ttys003", "--pid", "abc", "--cwd", "/"], ["--pid", "4242", "--cwd", "/"],
                      ["--tty", "/dev/ttys003", "--pid", "4242", "--cwd", "/", "--open", "https://example.com"]])
    func incompleteTerminalRejected(_ extra: [String]) {
        #expect(throws: NotifyError.self) { try Notify.message(["--plugin", "terminal", "--title", "x"] + extra, id: id, now: t0) }
    }

    @Test(arguments: [[], ["--plugin", "terminal"], ["--title", "x"], ["--plugin", "terminal", "--title"],
                       ["--plugin", "terminal", "--title", "x", "--fact", "no_equal_sign"], ["--plugin", "terminal", "--title", "x", "--color", "red"]])
    func usageErrors(_ args: [String]) {
        #expect(throws: NotifyError.self) { try Notify.message(args, id: id, now: t0) }
    }

    /// Non-compliant message (plugin id, outcome, URL) errors out before writing to disk, following same rules as App readers
    @Test(arguments: [["--plugin", "Terminal", "--title", "x"], ["--plugin", "terminal", "--title", "x", "--outcome", "violation"],
                      ["--plugin", "terminal", "--title", "x", "--open", "no scheme"]])
    func invalidMessages(_ args: [String]) {
        #expect(throws: NotifyError.self) { try Notify.message(args, id: id, now: t0) }
    }
}

/// `pipctl activity start|update|end --id <activity> …`: options same as notify, plus `--progress`, `--alert`
@Suite struct ActivityArguments {
    private func activity(_ event: String, _ extra: [String]) throws -> Message {
        try Message.parse(Notify.message(extra + ["--plugin", "dl", "--title", "Downloading"], id: id, now: t0, activity: event))
    }

    @Test func update() throws {
        let m = try activity("update", ["--id", "xcode", "--progress", "0.62", "--label", "7.4 / 12 GB", "--value", "1m left"])
        #expect(m.activity == .init(id: "xcode", event: .update, alert: false))
        #expect(m.block == .progress(0.62, label: "7.4 / 12 GB") && m.value == "1m left")
    }

    @Test func alertFlag() throws {
        #expect(try activity("start", ["--id", "x", "--alert"]).activity == .init(id: "x", event: .start, alert: true))
    }

    /// nan and inf parse as Double but cannot serialize to JSON (JSONSerialization raises uncaught NSException)
    @Test(arguments: [["--progress", "0.5"], ["--id", "x", "--progress", "abc"], ["--id", "x", "--progress", "nan"], ["--id", "x", "--progress", "inf"],
                      ["--id", "x", "--progress", "0.5", "--fact", "a=b"], ["--id", "x", "--group", "g"]])
    func usageErrors(_ extra: [String]) {
        #expect(throws: NotifyError.self) { try activity("update", extra) }
    }

    @Test func badEvent() {
        #expect(throws: NotifyError.self) { try activity("stop", ["--id", "x"]) }
    }

    /// Regular cards do not accept activity options
    @Test(arguments: [["--id", "x"], ["--alert"]])
    func notifyRejectsActivityOptions(_ extra: [String]) {
        #expect(throws: NotifyError.self) { try Notify.message(["--plugin", "dl", "--title", "x"] + extra, id: id, now: t0) }
    }
}

/// Timestamp includes fractional seconds: enables App to order start and end fired within same second
@Suite struct NotifyTimestamp {
    @Test func fractionalSeconds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000.25)
        let m = try Message.parse(Notify.message(["--plugin", "dl", "--title", "x"], id: id, now: now))
        #expect(m.at == now)
    }
}

/// Rich options requiring handcrafted JSON: buttons, text blocks, log blocks, checklist, switch app, stale
@Suite struct NotifyRichOptions {
    @Test func buttons() throws {
        let m = try notify(["--plugin", "ci", "--title", "x", "--button", "View log=https://example.com/log?id=1", "--button", "Rerun=raycast://x"])
        #expect(m.buttons == [.init(title: "View log", action: .open(URL(string: "https://example.com/log?id=1")!)),
                              .init(title: "Rerun", action: .open(URL(string: "raycast://x")!))])
    }

    @Test func textAndLog() throws {
        #expect(try notify(["--plugin", "ci", "--title", "x", "--text", "Line 1\nLine 2"]).block == .text(["Line 1", "Line 2"]))
        #expect(try notify(["--plugin", "ci", "--title", "x", "--log", "error: a\nerror: b"]).block == .log(["error: a", "error: b"]))
    }

    @Test func checklist() throws {
        let m = try notify(["--plugin", "ci", "--title", "x", "--check", "ok=Build", "--check", "failed=Test a=b", "--check", "pending=Deploy"])
        #expect(m.block == .checklist([.init(text: "Build", state: .ok), .init(text: "Test a=b", state: .failed), .init(text: "Deploy", state: .pending)]))
    }

    @Test func activate() throws {
        #expect(try notify(["--plugin", "ci", "--title", "x", "--activate", "com.apple.Safari"]).action == .activate(bundleID: "com.apple.Safari"))
    }

    @Test func stale() throws {
        #expect(try notify(["--plugin", "ci", "--title", "x", "--stale", "90"]).staleAt == t0.addingTimeInterval(90))
    }

    @Test(arguments: [["--button", "no_equal_sign"], ["--button", "=https://example.com"], ["--button", "a=no scheme"],
                      ["--button", "a=https://a.com", "--button", "b=https://b.com", "--button", "c=https://c.com"],
                      ["--check", "done=x"], ["--check", "no_equal_sign"], ["--text", "a", "--log", "b"], ["--text", "a", "--fact", "a=b"],
                      ["--check", "ok=a", "--progress", "0.5"], ["--activate", "com.apple.Safari", "--open", "https://example.com"],
                      ["--activate", "com.apple.Safari", "--tty", "/dev/ttys003", "--pid", "4242", "--cwd", "/"],
                      ["--stale", "abc"], ["--stale", "0"], ["--stale", "-5"]])
    func rejected(_ extra: [String]) {
        #expect(throws: NotifyError.self) { try Notify.message(["--plugin", "ci", "--title", "x"] + extra, id: id, now: t0) }
    }
}

/// `pipctl send`: full message on stdin. Fills in `v`, `id`, `at` if omitted; passes remainder to `Message.parse`
@Suite struct SendJSON {
    @Test func fillsEnvelope() throws {
        let data = try Notify.send(Data(#"{"plugin":"ci","title":"x","buttons":[{"type":"Action.OpenUrl","title":"View","url":"https://example.com"}]}"#.utf8),
                                   id: id, now: t0)
        let m = try Message.parse(data)
        #expect(m.plugin == "ci" && m.id == id && m.at == t0 && m.buttons.count == 1)
    }

    @Test func keepsGivenEnvelope() throws {
        let other = UUID()
        let data = try Notify.send(Data(#"{"v":1,"id":"\#(other.uuidString)","at":"2027-01-01T00:00:00Z","plugin":"ci","title":"x"}"#.utf8), id: id, now: t0)
        let m = try Message.parse(data)
        #expect(m.id == other && m.at == Date(timeIntervalSince1970: 1_798_761_600))
    }

    @Test(arguments: [#"not JSON"#, #"[1]"#, #"{"plugin":"ci"}"#, #"{"plugin":"ci","title":"x","outcome":"violation"}"#])
    func rejected(_ json: String) {
        #expect(throws: NotifyError.self) { try Notify.send(Data(json.utf8), id: id, now: t0) }
    }
}
