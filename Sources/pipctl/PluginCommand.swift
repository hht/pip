import AppKit
import Darwin
import Foundation
import NotchCore
import PluginCore
import PluginStore

/// Answers: what `pipctl plugin install|uninstall|list` does. Installing, uninstalling, and reading registration belong to `PluginStore`;
/// this layer only parses arguments and prints results.
/// After install or uninstall, App re-reads registration on next message received or when opening Settings, without restart.
enum PluginCommand {
    static let usage = """
        Usage: pipctl plugin install <plugin-dir>   Validates manifest.json, copies into plugins directory; backups old version if same id
               pipctl plugin uninstall <id>         Moves to backup (\(PluginPaths.backup.path))
               pipctl plugin list                   Installed external plugins: id, name, icon
        """

    static func run(_ args: [String]) -> Never {
        let store = PluginStore()
        do {
            switch (args.first, args.count) {
            case ("install"?, 2):
                let source = URL(fileURLWithPath: args[1])
                let result = try store.install(source, symbolExists: symbolExists, now: Date())
                print("Installed \(result.manifest.name) (\(result.manifest.id)): \(store.plugins.appendingPathComponent(result.manifest.id).path)")
                if let old = result.replaced { print("Old version moved to \(old.path)") }
            case ("uninstall"?, 2):
                print("Uninstalled \(args[1]), directory moved to \(try store.uninstall(args[1], now: Date()).path)")
            case ("list"?, 1):
                let manifests = store.manifests { dir, error in
                    FileHandle.standardError.write(Data("pipctl: \(dir ?? store.plugins.path) cannot be read or parsed (\(error)), treated as unregistered\n".utf8))
                }
                for m in manifests.values.sorted(by: { $0.id < $1.id }) {
                    print("\(m.id)\t\(m.name)\t\(m.symbol)\(symbolExists(m.symbol) ? "" : " (icon not found in system)")")
                }
            default:
                PipCtl.fail(usage, status: EX_USAGE)
            }
        } catch let problem as PluginStore.Problem {
            PipCtl.fail("pipctl: \(describe(problem))", status: EX_DATAERR)
        } catch {
            PipCtl.fail("pipctl: \(error.localizedDescription)", status: EX_CANTCREAT)
        }
        exit(0)
    }

    private static func symbolExists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// Matches terminology in Settings (`Problem.errorDescription` in `PluginManagement.swift`); update both together
    private static func describe(_ problem: PluginStore.Problem) -> String {
        switch problem {
        case .noManifest: return "Folder does not contain manifest.json"
        case .manifest(.malformed): return "manifest.json is not valid JSON, or missing id, name, symbol"
        case .manifest(.badID): return "id must only use lowercase letters, numbers, and hyphens, up to 32 characters"
        case .manifest(.reservedID): return "id is reserved for built-in plugins (guard, claude); please choose another"
        case .manifest(.missingField): return "name and symbol cannot be empty"
        case .manifest(.tooLong): return "name up to \(Card.maxValue) characters, symbol up to \(Manifest.maxSymbol) characters"
        case .unknownSymbol(let s): return "SF Symbol named \(s) not found in system (lookup available in SF Symbols app)"
        case .bundled: return "terminal is the built-in terminal plugin, install/uninstall in Settings › Terminal"
        case .alreadyInstalled: return "This folder is already the installed plugin"
        case .notInstalled: return "Plugin is not installed (run pipctl plugin list to see installed plugins)"
        case .exists: return "A plugin with the same id is already installed"
        }
    }
}
