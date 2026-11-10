#if DEBUG
import AppKit
import AgentCore
import NotchCore

/// `scripts/demo.sh` pop-up cards. Distributed notifications can be sent by any local process, so listen only in DEBUG builds (`CONFIG=debug scripts/run.sh`).
extension AppDelegate {
    func listenForDemo() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleCardNotification(_:)),
            name: Notification.Name("local.hht.notchkeeper.card"), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    /// scripts/demo.sh: agent cards attach to the most recently updated session, following the same pipeline as real cards (identical copy, click jumps to Ghostty); alert acts as new violation; blocks pops five content blocks;
    /// settings opens plugin settings (for taking screenshots on physical devices without manual clicks).
    @objc func handleCardNotification(_ n: Notification) {
        let kind = n.object as? String ?? ""
        if kind == "settings" {
            settings.show(.plugins)
            Log.write("External trigger: settings")
            return
        }
        if kind == "alert" {
            state.demoAlert()
            Log.write("External trigger: alert card")
            return
        }
        if kind == "blocks" {
            for card in Self.demoBlocks { notch.post(card, key: nil) }
            Log.write("External trigger: content blocks")
            return
        }
        // Any local process can send this notification: do not log unrecognized kinds to prevent log spoofing.
        let make: (Int32) -> AgentEvent
        switch kind {
        case "done": make = { .turnDone(pid: $0) }
        case "failed": make = { .turnFailed(pid: $0) }
        case "question": make = { .needsYou(.question, pid: $0) }
        case "approval": make = { .needsYou(.approval, pid: $0) }
        default: Log.write("External trigger: unrecognized card"); return
        }
        guard let s = state.sessions.max(by: { $0.stateSince < $1.stateSince }) else {
            Log.write("External trigger: no Claude Code sessions, will not show")
            return
        }
        notch.agentEvents([make(s.pid)], sessions: state.sessions)
        Log.write("External trigger: \(kind)")
    }

    /// `demo.sh blocks`: one card for each of the five content block types, attached to a mock external plugin.
    /// Created anew each time: card IDs differ per card just like real cards.
    static var demoBlocks: [Card] {
        let source = Card.Source.plugin(id: "demo", name: "Demo", symbol: "sparkles")
        return [
            Card(source: source, title: "npm finished", subtitle: "~/Projects/pip", value: "2m 13s", outcome: .done,
                 block: .facts([.init(title: "Exit code", value: "0"), .init(title: "Branch", value: "design/panel"),
                                .init(title: "Duration", value: "2:13"), .init(title: "Tests", value: "373")]),
                 buttons: [.init(title: "Open Finder", action: .activate(bundleID: "com.apple.finder")),
                           .init(title: "View Swift Docs", action: .open(URL(string: "https://www.swift.org/documentation/")!))]),
            Card(source: source, title: "swift test failed", subtitle: "~/Projects/pip", value: "41s", outcome: .failed,
                 block: .log(["✘ Test cardGrowsWithBlock() failed", "Expectation failed: 156 <= 150", "NotchLayoutTests.swift:21"]),
                 // Both card and button use intercepted schemes (different ones): clicking button logs ftp once, clicking blank area logs http once.
                 action: .open(URL(string: "http://example.com")!),
                 buttons: [.init(title: "View Logs", action: .open(URL(string: "ftp://example.com/log")!))]),
            Card(source: source, title: "Deployment", subtitle: "app 0.3.1", outcome: .info,
                 block: .checklist([.init(text: "Build", state: .ok), .init(text: "Unit tests", state: .failed), .init(text: "Upload", state: .pending)])),
            Card(source: source, title: "Downloading", subtitle: "Xcode_27.xip", value: "1m remaining", outcome: .info,
                 block: .progress(0.62, label: "7.4 / 12 GB")),
            Card(source: source, title: "Build notes", outcome: .attention,
                 block: .text(["**3 tests** failed, slowest was `GuardStateWatching`", "_All other_ 370 passed", "[Link disabled](https://example.com) ![Image disabled](file:///etc/hosts)"])),
        ]
    }
}
#endif
