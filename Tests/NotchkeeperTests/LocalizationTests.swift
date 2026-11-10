import Foundation
import Testing

/// String Catalog coverage (docs/ui.md "Localization"): every key has zh-Hans translation, no stale keys; Info.plist declares both languages.
/// When copy in code changes, run scripts/strings.sh first to sync, then add translations.
@Suite struct LocalizationCoverage {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Unit: Decodable { var state: String; var value: String }
                struct Variant: Decodable { var stringUnit: Unit }
                /// Sentences with numbers distinguish singular and plural ("Up to 1 row"), translations in variations.plural
                struct Variations: Decodable { var plural: [String: Variant]? }
                var stringUnit: Unit?
                var variations: Variations?

                var translated: Bool {
                    if let plural = variations?.plural {
                        return plural["other"] != nil && plural.values.allSatisfy { $0.stringUnit.state == "translated" && !$0.stringUnit.value.isEmpty }
                    }
                    return stringUnit?.state == "translated" && stringUnit?.value.isEmpty == false
                }
            }
            var shouldTranslate: Bool?
            var extractionState: String?
            var localizations: [String: Localization]?
        }
        var sourceLanguage: String
        var strings: [String: Entry]
    }

    private func catalog(_ name: String) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Self.root.appendingPathComponent("Resources/\(name).xcstrings")))
    }

    @Test(arguments: ["Localizable", "InfoPlist"])
    func everyKeyTranslated(_ name: String) throws {
        let c = try catalog(name)
        #expect(c.sourceLanguage == "en")
        #expect(!c.strings.isEmpty)
        for (key, entry) in c.strings where entry.shouldTranslate != false {
            #expect(entry.localizations?["zh-Hans"]?.translated == true, "\(name): \"\(key)\" missing zh-Hans")
        }
    }

    /// English distinguishes singular/plural where count can be 1
    @Test func pluralsWhereCountVaries() throws {
        let plural = try catalog("Localizable").strings["Up to %lld rows"]?.localizations?["en"]?.variations?.plural
        #expect(plural?["one"]?.stringUnit.value == "Up to %lld row")
    }

    /// stale: no longer in code, remove
    @Test(arguments: ["Localizable", "InfoPlist"])
    func noStaleKeys(_ name: String) throws {
        let stale = try catalog(name).strings.filter { $0.value.extractionState == "stale" }.keys.sorted()
        #expect(stale.isEmpty, "\(name) stale keys: \(stale)")
    }

    /// No CFBundleAllowMixedLocalizations: in Japanese environment it resolved to en but showed Chinese (docs/ui.md "Localization")
    @Test func infoPlistDeclaresLanguages() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Support/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(plist["CFBundleLocalizations"] as? [String] == ["zh-Hans", "en"])
        #expect(plist["CFBundleAllowMixedLocalizations"] == nil)
    }
}
