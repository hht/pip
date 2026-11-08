import AppKit
import SwiftUI

/// Responds on the first click (no need to first click to "activate" an inactive panel)
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PressableStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

enum Apps {
    /// Switches to this app: brings to front if running, launches if not. Returns false if not installed.
    /// Delegated to `/usr/bin/open -b`: macOS 14+ activation is cooperative; notch panel does not activate itself, cannot yield foreground.
    /// Tested from background processes: `NSRunningApplication.activate()` and `NSWorkspace.openApplication` cannot switch,
    /// while `open -b` and AppleScript `activate` can; the latter prompts for Automation permissions per app, so former is used.
    /// Bundle ID passed as argument, no shell involved.
    /// @see https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:)
    @discardableResult
    static func activate(_ bundleID: String) -> Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return false }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", bundleID]
        do { try open.run() } catch { Log.write("Failed to switch App: \((error as NSError).domain) \((error as NSError).code)") }
        return true
    }
}

/// Operation failure with a user-facing explanation (Settings displays `localizedDescription`)
struct Failure: LocalizedError {
    var errorDescription: String?
}

extension FileManager {
    /// Replaces `destination` with a copy of `source`: copies to a staging directory on the same volume first,
    /// so if copy fails midway the original is preserved
    func replaceItem(at destination: URL, withCopyOf source: URL) throws {
        try createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = try url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination.deletingLastPathComponent(), create: true)
            .appendingPathComponent(destination.lastPathComponent)
        defer {
            // Temporary staging directory is empty after replacement; failure to delete only leaves an empty folder
            do { try removeItem(at: staging.deletingLastPathComponent()) } catch { Log.write("Cannot delete temporary directory: \(error.localizedDescription)") }
        }
        try copyItem(at: source, to: staging)
        if fileExists(atPath: destination.path) {
            _ = try replaceItemAt(destination, withItemAt: staging)
        } else {
            try moveItem(at: staging, to: destination)
        }
    }
}

/// Notch expand (including cards), collapse, return from cards to panel, and panel row transitions (docs/mascot.md §5 "Collapse and Expand").
/// Tightens springs to non-bouncing when "Reduce Motion" is enabled (HIG Accessibility: "Tightening animation springs to reduce bounce effects");
/// re-checks system settings on every access to apply changes immediately
/// @see https://developer.apple.com/design/human-interface-guidelines/accessibility
enum NotchSpring {
    static var page: Animation { spring(response: 0.42, dampingFraction: 0.84) }
    static var notchOpen: Animation { spring(response: 0.5, dampingFraction: 0.7) }
    static var notchClose: Animation { spring(response: 0.38, dampingFraction: 0.88) }

    private static func spring(response: Double, dampingFraction: Double) -> Animation {
        .spring(response: response, dampingFraction: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : dampingFraction)
    }
}

/// Relative time text: "Last Check" in Settings, session row timestamps. Always describes the past: freshly written guard status
/// or clock skews that are equal to or slightly ahead of now formatted as "in 0 seconds" are adjusted to 1 second ago
/// @see https://developer.apple.com/documentation/foundation/relativedatetimeformatter
enum AgoText {
    static func string(_ date: Date, now: Date = .now, locale: Locale = .autoupdatingCurrent) -> String {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .numeric
        f.unitsStyle = .short
        f.locale = locale
        return f.localizedString(for: min(date, now.addingTimeInterval(-1)), relativeTo: now)
    }
}
