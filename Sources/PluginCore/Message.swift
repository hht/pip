import Foundation
import NotchCore

/// Answers: what a file in inbox says — which plugin, which card, replacement group, expiration.
/// Only parses v1 messages (card-only); does not read files, unaware of plugin registration or rate limits (`InboxGate`).
/// Content blocks and actions follow Adaptive Cards naming (TextBlock, FactSet, Action.OpenUrl, buttons are actions with titles); progress, checklist, activate, and focusTerminal are extensions.
/// @see https://github.com/microsoft/AdaptiveCards/tree/main/schemas/src
public struct Message: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case open(URL)
        case activate(bundleID: String)
        /// Switch back to terminal: tty is `/dev/ttys` + number, pid is process using it (shell)
        case focusTerminal(tty: String, pid: Int32, cwd: String)
    }

    public struct Button: Equatable, Sendable {
        public var title: String
        public var action: Action
    }

    /// Step in an activity (following ActivityKit start / update / end). Activities occupy a row in plugin panel section; alert pops card, subsequent updates refresh it in-place
    /// @see https://developer.apple.com/documentation/activitykit/activity
    public struct Activity: Equatable, Sendable {
        public enum Event: Equatable, Sendable { case start, update, end }
        /// Plugin-defined name, identifies activity within plugin
        public var id: String
        public var event: Event
        public var alert: Bool
    }

    public var plugin: String
    public var id: UUID
    public var at: Date
    /// Cards with same group within plugin only keep latest
    public var group: String?
    public var title: String
    public var subtitle: String?
    public var value: String?
    /// Only done, failed, attention, info: red and green belong to egress guard
    public var outcome: Card.Outcome
    public var block: Card.Block?
    public var action: Action?
    public var buttons: [Button]
    /// Discard if not displayed before this timestamp; for activities, when this row expires
    public var staleAt: Date?
    /// nil: regular card, not an activity
    public var activity: Activity?

    /// Max size for one message: cards display at most a few hundred chars, larger payloads are erroneous
    public static let maxBytes = 64 * 1024

    public static func parse(_ data: Data) throws(MessageError) -> Message {
        let wire: Wire
        do {
            wire = try decoder.decode(Wire.self, from: data)
        } catch {
            throw .malformed
        }
        return try Message(wire)
    }

    /// Plugin id is formatted into `plugins/<id>/manifest.json`: starts with lowercase letter or digit, contains only lowercase letters, digits, and hyphens, up to 32 chars
    public static func isPluginID(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, s.unicodeScalars.count <= 32, first != "-" else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// Scripts often use `date -u +%FT%TZ`, JS `toISOString()` includes millis: macOS 26.5 `.iso8601` accepts both
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// In extension: preserve compiler-synthesized memberwise init (used in tests)
extension Message {
    private init(_ wire: Wire) throws(MessageError) {
        guard wire.v == 1 else { throw .unsupportedVersion }
        guard Self.isPluginID(wire.plugin) else { throw .badPluginID }
        guard !wire.title.allSatisfy(\.isWhitespace) else { throw .missingTitle }
        plugin = wire.plugin
        id = wire.id
        at = wire.at
        group = wire.group
        title = wire.title
        subtitle = wire.subtitle
        value = wire.value
        switch wire.outcome ?? "info" {
        case "done": outcome = .done
        case "failed": outcome = .failed
        case "attention": outcome = .attention
        case "info": outcome = .info
        default: throw .unknownOutcome
        }
        block = try wire.block.map(Self.block)
        action = try wire.action.map(Self.action)
        buttons = try (wire.buttons ?? []).map { a throws(MessageError) in
            guard let title = a.title, !title.allSatisfy(\.isWhitespace) else { throw .badAction }
            return Button(title: title, action: try Self.action(a))
        }
        staleAt = wire.staleAt
        activity = try wire.activity.map { a throws(MessageError) in
            guard !a.id.isEmpty, a.id.count <= 64 else { throw .badActivity }
            let event: Activity.Event
            switch a.event {
            case "start": event = .start
            case "update": event = .update
            case "end": event = .end
            default: throw .badActivity
            }
            return Activity(id: a.id, event: event, alert: a.alert ?? false)
        }
    }

    private static func block(_ b: Wire.Block) throws(MessageError) -> Card.Block {
        switch b.type {
        case "TextBlock":
            guard let text = b.text else { throw .badBlock }
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            switch b.fontType?.lowercased() {
            case nil, "default": return .text(lines)
            case "monospace": return .log(lines)
            default: throw .badBlock
            }
        case "FactSet":
            guard let facts = b.facts else { throw .badBlock }
            return .facts(facts.map { Card.Fact(title: $0.title, value: $0.value) })
        case "checklist":
            guard let items = b.items else { throw .badBlock }
            return .checklist(try items.map { item throws(MessageError) in
                switch item.state {
                case "ok": return Card.Check(text: item.text, state: .ok)
                case "failed": return Card.Check(text: item.text, state: .failed)
                case "pending": return Card.Check(text: item.text, state: .pending)
                default: throw .badBlock
                }
            })
        case "progress":
            guard let value = b.value else { throw .badBlock }
            return .progress(value, label: b.label)
        default:
            throw .badBlock
        }
    }

    private static func action(_ a: Wire.Action) throws(MessageError) -> Action {
        switch a.type {
        case "Action.OpenUrl":
            guard let url = a.url.flatMap(URL.init(string:)), url.scheme != nil else { throw .badAction }
            return .open(url)
        case "activate":
            guard let id = a.bundleID, !id.isEmpty else { throw .badAction }
            return .activate(bundleID: id)
        case "focusTerminal":
            // tty will be opened to write mark: only accept macOS pseudo-terminal names, prevent path traversal
            guard let tty = a.tty, tty.hasPrefix("/dev/ttys"), tty.count > 9, tty.dropFirst(9).allSatisfy({ $0.isASCII && $0.isNumber }),
                  let pid = a.pid, pid > 1, let cwd = a.cwd else { throw .badAction }
            return .focusTerminal(tty: tty, pid: pid, cwd: cwd)
        default:
            throw .badAction
        }
    }
}

/// Reason why message cannot be decoded: App counts and deletes file. Omits original message content (external input, may be lengthy or forged)
public enum MessageError: Error, Equatable, Sendable {
    /// Not JSON, missing required fields, or type mismatch
    case malformed
    case unsupportedVersion
    case badPluginID
    case missingTitle
    /// External plugins can only use done, failed, attention, info
    case unknownOutcome
    /// Unknown block type or missing fields
    case badBlock
    /// Unknown action type, missing fields, or button without title
    case badAction
    /// Activity id is empty or too long, or unknown event
    case badActivity
}

/// JSON format of inbox file (also assembled by `pipctl`). Missing fields or wrong types fail here
private struct Wire: Decodable {
    var v: Int
    var plugin: String
    var id: UUID
    var at: Date
    var group: String?
    var title: String
    var subtitle: String?
    var value: String?
    /// Defaults to info
    var outcome: String?
    var block: Block?
    var action: Action?
    var buttons: [Action]?
    var staleAt: Date?
    var activity: Activity?

    struct Activity: Decodable {
        var id: String
        /// start, update, end
        var event: String
        var alert: Bool?
    }

    /// `type` is TextBlock, FactSet, checklist, progress, each using its own fields
    struct Block: Decodable {
        var type: String
        var text: String?
        var fontType: String?
        var facts: [Fact]?
        var items: [Item]?
        var value: Double?
        var label: String?

        struct Fact: Decodable {
            var title: String
            var value: String
        }

        struct Item: Decodable {
            var text: String
            /// ok, failed, pending
            var state: String
        }
    }

    /// `type` is Action.OpenUrl (`url`), activate (`bundleID`), or focusTerminal (`tty`, `pid`, `cwd`); button requires `title`
    struct Action: Decodable {
        var type: String
        var title: String?
        var url: String?
        var bundleID: String?
        var tty: String?
        var pid: Int32?
        var cwd: String?
    }
}
