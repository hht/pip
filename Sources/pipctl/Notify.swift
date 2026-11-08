import Foundation
import NotchCore
import PluginCore

/// Answers: which card or which step of an activity the arguments of `pipctl notify …`, `pipctl activity …`,
/// or JSON read by `pipctl send` correspond to.
/// Assembles inbox JSON and validates via `Message.parse`: anything written here is guaranteed parseable by App.
enum Notify {
    static let usage = """
        Usage: pipctl notify --plugin <id> --title <title> [--subtitle <subtitle>] [--value <short-value>]
                            [--outcome done|failed|attention|info] [--group <group>] [--stale <seconds>]
                            [--fact <key>=<value>... | --check ok|failed|pending=<text>... | --text <text> | --log <text> | --progress <0…1> [--label <description>]]
                            [--open <URL> | --activate <bundle ID> | --tty <tty> --pid <pid> --cwd <dir>] [--button <title>=<URL>]...
              pipctl activity start|update|end --id <activity> [--alert] [notify options except --group] (requires --title each step, end writes final outcome)
                            Activity occupies a row in panel plugins section, end removes it; --alert pops a card, subsequent updates refresh that card in place
              pipctl send < message.json   Full message on standard input (see user guide for schema), fills in v, id, at if omitted
        """

    /// activity: start, update, end; nil is a regular card
    static func message(_ args: [String], id: UUID, now: Date, activity: String? = nil) throws(NotifyError) -> Data {
        var fields = envelope(id: id, now: now)
        var blocks: [[String: Any]] = []
        var facts: [[String: String]] = []
        var checks: [[String: String]] = []
        var progress: [String: Any] = [:]
        var terminal: [String: Any] = [:]
        var actions: [[String: Any]] = []
        var buttons: [[String: Any]] = []
        var activityFields: [String: Any] = [:]
        if let activity { activityFields["event"] = activity }
        var rest = args[...]
        while let option = rest.popFirst() {
            if option == "--alert" {
                guard activity != nil else { throw .usage("--alert is only valid for pipctl activity") }
                activityFields["alert"] = true
                continue
            }
            guard let value = rest.popFirst() else { throw .usage("Missing value after \(option)") }
            switch option {
            case "--id":
                guard activity != nil else { throw .usage("--id is only valid for pipctl activity") }
                activityFields["id"] = value
            case "--progress":
                guard let p = Double(value), p.isFinite else { throw .usage("--progress must be a number between 0 and 1") }
                progress["value"] = p
            case "--label":
                progress["label"] = value
            case "--plugin", "--title", "--subtitle", "--value", "--outcome", "--group":
                fields[String(option.dropFirst(2))] = value
            case "--stale":
                guard let seconds = TimeInterval(value), seconds > 0 else { throw .usage("--stale must be seconds greater than 0") }
                fields["staleAt"] = timestamp(now.addingTimeInterval(seconds))
            case "--fact":
                let (name, rest) = try split(value, option)
                facts.append(["title": name, "value": rest])
            case "--check":
                // State first: text may contain equal signs
                let (state, text) = try split(value, option)
                checks.append(["state": state, "text": text])
            case "--text", "--log":
                blocks.append(["type": "TextBlock", "text": value, "fontType": option == "--log" ? "monospace" : "default"])
            case "--open":
                actions.append(["type": "Action.OpenUrl", "url": value])
            case "--activate":
                actions.append(["type": "activate", "bundleID": value])
            case "--button":
                // Title first: URLs frequently contain equal signs
                let (title, url) = try split(value, option)
                buttons.append(["type": "Action.OpenUrl", "title": title, "url": url])
            case "--tty", "--cwd":
                terminal[String(option.dropFirst(2))] = value
            case "--pid":
                guard let pid = Int32(value) else { throw .usage("--pid must be a number") }
                terminal["pid"] = pid
            default:
                throw .usage("Unrecognized option: \(option)")
            }
        }
        guard fields["plugin"] != nil, fields["title"] != nil else { throw .usage("--plugin and --title are required") }
        if !terminal.isEmpty {
            guard terminal.count == 3 else { throw .usage("--tty, --pid, --cwd must be provided together") }
            actions.append(terminal.merging(["type": "focusTerminal"]) { a, _ in a })
        }
        guard actions.count <= 1 else { throw .usage("--open, --activate, and jump to terminal are mutually exclusive") }
        fields["action"] = actions.first
        guard buttons.count <= Card.maxButtons else { throw .usage("--button allows at most \(Card.maxButtons)") }
        if !buttons.isEmpty { fields["buttons"] = buttons }
        if activity != nil {
            guard activityFields["id"] != nil else { throw .usage("pipctl activity requires --id") }
            // Activity cards are identified by activity; group is not used
            guard fields["group"] == nil else { throw .usage("--group is only valid for pipctl notify") }
            fields["activity"] = activityFields
        }
        if !facts.isEmpty { blocks.append(["type": "FactSet", "facts": facts]) }
        if !checks.isEmpty { blocks.append(["type": "checklist", "items": checks]) }
        if !progress.isEmpty {
            guard progress["value"] != nil else { throw .usage("--label must be provided with --progress") }
            blocks.append(progress.merging(["type": "progress"]) { a, _ in a })
        }
        guard blocks.count <= 1 else { throw .usage("--fact, --check, --text, --log, --progress are mutually exclusive: a card has at most one content block") }
        fields["block"] = blocks.first
        return try validated(fields)
    }

    /// `pipctl send`: full message. Only supplements `v`, `id`, `at`; other fields passed verbatim to `Message.parse`
    static func send(_ input: Data, id: UUID, now: Date) throws(NotifyError) -> Data {
        guard input.count <= Message.maxBytes else { throw .usage("Message exceeds \(Message.maxBytes / 1024) KB") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: input)
        } catch {
            throw .invalid(.malformed)
        }
        guard let fields = object as? [String: Any] else { throw .invalid(.malformed) }
        return try validated(envelope(id: id, now: now).merging(fields) { _, given in given })
    }

    private static func envelope(id: UUID, now: Date) -> [String: Any] {
        ["v": 1, "id": id.uuidString, "at": timestamp(now)]
    }

    /// Includes milliseconds: scripts firing start and end within one second allow App to order them correctly
    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    /// Splits `key=value` at the first equal sign; neither side may be empty
    private static func split(_ value: String, _ option: String) throws(NotifyError) -> (String, String) {
        guard let eq = value.firstIndex(of: "="), eq != value.startIndex else { throw .usage("\(option) must be formatted as key=value") }
        return (String(value[..<eq]), String(value[value.index(after: eq)...]))
    }

    private static func validated(_ fields: [String: Any]) throws(NotifyError) -> Data {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            preconditionFailure("Both assembled and input values are valid JSON")
        }
        do {
            _ = try Message.parse(data)
        } catch {
            throw .invalid(error)
        }
        return data
    }
}

enum NotifyError: Error {
    case usage(String)
    case invalid(MessageError)
}
