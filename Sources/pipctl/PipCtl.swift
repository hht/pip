import Darwin
import Foundation
import PluginCore

/// Answers: how external plugins send a card or report an activity to Notchkeeper (`plugin` subcommand see `PluginCommand`).
/// `pipctl notify …`, `pipctl activity …` validate and write into inbox: write `tmp/<id>.json` first, then rename to `new/` (atomic across same filesystem).
/// Does not wait for App to read, agnostic of plugin registration (App validates). If App was never launched and inbox directory does not exist, errors and exits.
@main
enum PipCtl {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let activity: String?
        let rest: [String]
        switch args.first {
        case "notify"?:
            (activity, rest) = (nil, Array(args.dropFirst()))
        case "activity"? where args.count > 1:
            (activity, rest) = (args[1], Array(args.dropFirst(2)))
        case "send"? where args.count == 1:
            (activity, rest) = (nil, [])
        case "plugin"?:
            PluginCommand.run(Array(args.dropFirst()))
        default:
            fail(Notify.usage + "\n" + PluginCommand.usage, status: EX_USAGE)
        }
        let id = UUID()
        let data: Data
        do {
            if args.first == "send" {
                // Reading up to maxBytes + 1 is sufficient to detect oversized payload without draining infinite pipe
                let input = FileHandle.standardInput.readData(ofLength: Message.maxBytes + 1)
                data = try Notify.send(input, id: id, now: Date())
            } else {
                data = try Notify.message(rest, id: id, now: Date(), activity: activity)
            }
        } catch {
            switch error {
            case .usage(let why): fail("pipctl: \(why)\n\(Notify.usage)", status: EX_USAGE)
            case .invalid(let error): fail("pipctl: invalid message (\(error))", status: EX_DATAERR)
            }
        }
        let name = id.uuidString + ".json"
        let tmp = PluginPaths.tmp.appendingPathComponent(name)
        do {
            try data.write(to: tmp)
        } catch {
            fail("pipctl: cannot write to inbox (\(PluginPaths.tmp.path)), has Pip been launched? \(error.localizedDescription)", status: EX_CANTCREAT)
        }
        guard rename(tmp.path, PluginPaths.new.appendingPathComponent(name).path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(tmp.path)
            fail("pipctl: cannot deliver to inbox (\(why))", status: EX_CANTCREAT)
        }
    }

    static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }
}
