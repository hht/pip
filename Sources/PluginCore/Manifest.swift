import Foundation
import NotchCore

/// Answers: whether an external plugin is registered, what name and icon it shows on cards. Loaded from `plugins/<id>/manifest.json`, does not read files directly
public struct Manifest: Equatable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbol name
    public var symbol: String

    /// Longest system icon name is around 40 characters
    public static let maxSymbol = 64

    /// Directory name is the plugin id: reject mismatches to prevent impersonation. nil: plugin to be installed, not yet in `plugins/<id>/`
    public static func parse(_ data: Data, directoryName: String?) throws(ManifestError) -> Manifest {
        struct Wire: Decodable { var id, name, symbol: String }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw .malformed
        }
        guard wire.id == directoryName ?? wire.id, Message.isPluginID(wire.id) else { throw .badID }
        guard !PluginID.builtIn.contains(wire.id) else { throw .reservedID }
        guard !wire.name.allSatisfy(\.isWhitespace), !wire.symbol.isEmpty else { throw .missingField }
        // Only block on install: already-installed plugins still receive cards normally; name truncated by `Card`, mismatched icon replaced with puzzle piece by App
        guard directoryName != nil || (wire.name.count <= Card.maxValue && wire.symbol.count <= maxSymbol) else { throw .tooLong }
        return Manifest(id: wire.id, name: wire.name, symbol: wire.symbol)
    }
}

/// Registration file cannot be decoded: plugin is considered unregistered
public enum ManifestError: Error, Equatable, Sendable {
    case malformed
    /// Invalid, or does not match directory name
    case badID
    /// Reserved built-in plugin id (`PluginID.builtIn`)
    case reservedID
    case missingField
    /// On install: name exceeds `Card.maxValue` characters, or symbol exceeds `Manifest.maxSymbol`
    case tooLong
}
