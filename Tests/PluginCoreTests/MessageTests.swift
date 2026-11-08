import Foundation
import Testing
import NotchCore
@testable import PluginCore

private let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

private func parse(_ json: String) throws -> Message { try Message.parse(Data(json.utf8)) }

/// Message with required fields only, `extra` appended at the end
private func minimal(_ extra: String = "") -> String {
    #"{"v":1,"plugin":"terminal","id":"\#(id)","at":"2026-10-31T08:00:00Z","title":"npm finished","outcome":"done"\#(extra)}"#
}

@Suite struct MessageParsing {
    @Test func minimalMessage() throws {
        let m = try parse(minimal())
        #expect(m.plugin == "terminal")
        #expect(m.id == UUID(uuidString: id))
        #expect(m.at == Date(timeIntervalSince1970: 1_793_433_600))
        #expect(m.title == "npm finished")
        #expect(m.outcome == .done)
        #expect(m.subtitle == nil && m.value == nil && m.group == nil && m.block == nil && m.action == nil && m.buttons.isEmpty && m.staleAt == nil)
    }
}

@Suite struct MessageRejection {
    @Test(arguments: [("done", Card.Outcome.done), ("failed", .failed), ("attention", .attention), ("info", .info)])
    func outcomes(_ raw: String, _ outcome: Card.Outcome) throws {
        #expect(try parse(minimal().replacingOccurrences(of: #""outcome":"done""#, with: #""outcome":"\#(raw)""#)).outcome == outcome)
    }

    /// Red and green belong to egress guard: external messages using them are rejected directly rather than downgraded
    @Test(arguments: ["violation", "recovered", "question", "approval", "DONE", ""])
    func otherOutcomesRejected(_ raw: String) {
        #expect(throws: MessageError.unknownOutcome) {
            try parse(minimal().replacingOccurrences(of: #""outcome":"done""#, with: #""outcome":"\#(raw)""#))
        }
    }

    /// Missing fields use default values: outcome is info (consistent with `pipctl`)
    @Test func missingOutcomeIsInfo() throws {
        #expect(try parse(minimal().replacingOccurrences(of: #","outcome":"done""#, with: "")).outcome == .info)
    }

    @Test func otherVersionRejected() {
        #expect(throws: MessageError.unsupportedVersion) { try parse(minimal().replacingOccurrences(of: #""v":1"#, with: #""v":2"#)) }
    }

    @Test(arguments: ["{", "[]", #"{"v":1}"#, minimal().replacingOccurrences(of: id, with: "not-a-uuid"),
                      minimal().replacingOccurrences(of: "2026-10-31T08:00:00Z", with: "yesterday"),
                      minimal().replacingOccurrences(of: #""title":"npm finished""#, with: #""title":3"#)])
    func malformedRejected(_ json: String) {
        #expect(throws: MessageError.malformed) { try parse(json) }
    }

    @Test(arguments: ["", "  ", "\n"])
    func blankTitleRejected(_ title: String) {
        #expect(throws: MessageError.missingTitle) {
            try parse(minimal().replacingOccurrences(of: "npm finished", with: title.replacingOccurrences(of: "\n", with: #"\n"#)))
        }
    }

    /// Plugin id is formatted into `plugins/<id>/manifest.json`: only lowercase letters, digits, and hyphens allowed
    @Test(arguments: ["", "Terminal", "../x", "a/b", "a b", ".hidden", "-x", String(repeating: "a", count: 33)])
    func badPluginIDRejected(_ plugin: String) {
        #expect(throws: MessageError.badPluginID) {
            try parse(minimal().replacingOccurrences(of: #""plugin":"terminal""#, with: #""plugin":"\#(plugin)""#))
        }
    }

    @Test func unknownFieldsIgnored() throws {
        #expect(try parse(minimal(#","sound":"Basso","future":{"x":[1]}"#)).title == "npm finished")
    }

    @Test func fractionalSecondsAccepted() throws {
        let m = try parse(minimal(#","staleAt":"2026-10-31T08:10:00.250Z""#).replacingOccurrences(of: "08:00:00Z", with: "08:00:00.5+08:00"))
        #expect(m.at == Date(timeIntervalSince1970: 1_793_433_600 - 8 * 3600 + 0.5))
        #expect(m.staleAt == Date(timeIntervalSince1970: 1_793_434_200.25))
    }
}

/// Content blocks follow Adaptive Cards: TextBlock (fontType monospace is log), FactSet; progress and checklist are extensions
@Suite struct MessageBlocks {
    private func block(_ json: String) throws -> Card.Block? { try parse(minimal(#","block":\#(json)"#)).block }

    /// Body text splits on newlines, blank lines ignored
    @Test func textSplitsOnNewlines() throws {
        #expect(try block(#"{"type":"TextBlock","text":"Line 1\n\nLine 2\r\nLine 3 Line 4"}"#) == .text(["Line 1", "Line 2", "Line 3", "Line 4"]))
    }

    /// Adaptive Cards schema specifies Monospace
    @Test(arguments: ["monospace", "Monospace"])
    func monospaceTextIsLog(_ font: String) throws {
        #expect(try block(#"{"type":"TextBlock","text":"a\nb","fontType":"\#(font)"}"#) == .log(["a", "b"]))
    }

    @Test func defaultFontIsText() throws {
        #expect(try block(#"{"type":"TextBlock","text":"a","fontType":"default"}"#) == .text(["a"]))
    }

    @Test func factSet() throws {
        #expect(try block(#"{"type":"FactSet","facts":[{"title":"Exit code","value":"1"},{"title":"Directory","value":"~/x"}]}"#)
            == .facts([.init(title: "Exit code", value: "1"), .init(title: "Directory", value: "~/x")]))
    }

    @Test func checklist() throws {
        #expect(try block(#"{"type":"checklist","items":[{"text":"Build","state":"ok"},{"text":"Test","state":"failed"},{"text":"Upload","state":"pending"}]}"#)
            == .checklist([.init(text: "Build", state: .ok), .init(text: "Test", state: .failed), .init(text: "Upload", state: .pending)]))
    }

    @Test func progress() throws {
        #expect(try block(#"{"type":"progress","value":0.62,"label":"7.4 / 12 GB"}"#) == .progress(0.62, label: "7.4 / 12 GB"))
        #expect(try block(#"{"type":"progress","value":1}"#) == .progress(1, label: nil))
    }

    @Test(arguments: [#"{"type":"Image","url":"file:///etc/hosts"}"#, #"{"type":"TextBlock"}"#, #"{"type":"TextBlock","text":"a","fontType":"serif"}"#,
                      #"{"type":"FactSet"}"#, #"{"type":"checklist","items":[{"text":"a","state":"done"}]}"#, #"{"type":"progress"}"#])
    func badBlockRejected(_ json: String) {
        #expect(throws: MessageError.badBlock) { try block(json) }
    }

    /// Block missing type or key missing value: malformed JSON structure
    @Test(arguments: [#"{"text":"a"}"#, #"{"type":"FactSet","facts":[{"title":"a"}]}"#])
    func shapelessBlockIsMalformed(_ json: String) {
        #expect(throws: MessageError.malformed) { try block(json) }
    }
}

/// Clicking cards or buttons only opens URLs or switches apps (CLAUDE.md hard rule "Plugins"); URLs checked by `URLPolicy` on click
@Suite struct MessageActions {
    @Test func openURL() throws {
        let m = try parse(minimal(#","action":{"type":"Action.OpenUrl","url":"https://example.com/x"}"#))
        #expect(m.action == .open(URL(string: "https://example.com/x")!))
    }

    @Test func activate() throws {
        let m = try parse(minimal(#","action":{"type":"activate","bundleID":"com.apple.finder"}"#))
        #expect(m.action == .activate(bundleID: "com.apple.finder"))
    }

    /// Jump to terminal: tty identifies Ghostty window (writing one-shot title), pid matches tty
    @Test func focusTerminal() throws {
        let m = try parse(minimal(#","action":{"type":"focusTerminal","tty":"/dev/ttys003","pid":4242,"cwd":"/Users/x/p"}"#))
        #expect(m.action == .focusTerminal(tty: "/dev/ttys003", pid: 4242, cwd: "/Users/x/p"))
    }

    /// tty is opened to write: only /dev/ttys + number accepted (macOS pseudo-terminal)
    @Test(arguments: [#""tty":"/etc/passwd","pid":4242"#, #""tty":"/dev/ttys","pid":4242"#, #""tty":"/dev/ttys003/../disk0","pid":4242"#,
                      #""tty":"/dev/disk0","pid":4242"#, #""tty":"/dev/ttys003","pid":1"#, #""tty":"/dev/ttys003","pid":0"#])
    func badTerminalRejected(_ fields: String) {
        #expect(throws: MessageError.badAction) { try parse(minimal(#","action":{"type":"focusTerminal",\#(fields),"cwd":"/"}"#)) }
    }

    /// Buttons are actions with title (Adaptive Cards actions)
    @Test func buttons() throws {
        let m = try parse(minimal(#","buttons":[{"type":"Action.OpenUrl","title":"Read docs","url":"raycast://x"},{"type":"activate","title":"Open Finder","bundleID":"com.apple.finder"}]"#))
        #expect(m.buttons == [.init(title: "Read docs", action: .open(URL(string: "raycast://x")!)),
                              .init(title: "Open Finder", action: .activate(bundleID: "com.apple.finder"))])
    }

    /// Commands to execute are rejected (CLAUDE.md hard rule "Plugins")
    @Test(arguments: [#"{"type":"Action.Execute","verb":"rm"}"#, #"{"type":"shell","command":"rm -rf ~"}"#, #"{"type":"Action.OpenUrl"}"#,
                      #"{"type":"Action.OpenUrl","url":"no scheme"}"#, #"{"type":"activate","bundleID":""}"#])
    func badActionRejected(_ json: String) {
        #expect(throws: MessageError.badAction) { try parse(minimal(#","action":\#(json)"#)) }
    }

    @Test func buttonWithoutTitleRejected() {
        #expect(throws: MessageError.badAction) { try parse(minimal(#","buttons":[{"type":"Action.OpenUrl","url":"https://example.com"}]"#)) }
    }
}

/// Activities (following ActivityKit start / update / end): a row in plugin panel section, alert pops card
@Suite struct ActivityParsing {
    @Test(arguments: [("start", Message.Activity.Event.start), ("update", .update), ("end", .end)])
    func events(_ raw: String, _ event: Message.Activity.Event) throws {
        let m = try parse(minimal(#","activity":{"id":"xcode","event":"\#(raw)"}"#))
        #expect(m.activity == Message.Activity(id: "xcode", event: event, alert: false))
    }

    @Test func alert() throws {
        #expect(try parse(minimal(#","activity":{"id":"x","event":"update","alert":true}"#)).activity?.alert == true)
    }

    @Test func plainMessageHasNoActivity() throws {
        #expect(try parse(minimal()).activity == nil)
    }

    /// id is used only in-memory as key: cannot be empty or too long
    @Test(arguments: [#"{"id":"","event":"start"}"#, #"{"id":"x","event":"stop"}"#,
                      #"{"id":"\#(String(repeating: "a", count: 65))","event":"start"}"#])
    func badActivityRejected(_ activity: String) {
        #expect(throws: MessageError.badActivity) { try parse(minimal(#","activity":\#(activity)"#)) }
    }
}
