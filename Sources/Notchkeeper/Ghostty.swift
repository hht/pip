import AppKit
import NotchCore

/// Answers: When clicking a terminal session, which window in Ghostty belongs to it and how to focus it; whether the terminal specified by an external plugin is currently focused right in front of user (docs/agent-integration.md "Jumping to Ghostty").
/// Sends Apple Events only upon user click or when an external plugin card arrives and Ghostty is frontmost (`isFocused`, reads directory only), without polling; runs on a dedicated serial queue so initial system permission prompts or Ghostty stalls never block the main thread.
/// Agnostic to cards and panels.
/// @see /Applications/Ghostty.app/Contents/Resources/Ghostty.sdef (Ghostty 1.3: terminal id, name, working directory, focus command; no tty, pid)
enum Ghostty {
    struct Terminal {
        var id: String
        /// Session title set by Claude Code, possibly inferred from conversation: used only in memory to locate markers and restore original title; never displayed or logged.
        var title: String
        var workingDirectory: String
    }

    private static let bundleID = "com.mitchellh.ghostty"
    /// NSAppleScript is not thread-safe: execute only on this queue.
    private static let queue = DispatchQueue(label: "com.notchkeeper.ghostty")
    /// Maximum wait time for each Apple Event (default ~2 min).
    private static let timeout = "with timeout of 3 seconds"
    /// Ghostty parses tty output on IO thread then updates title on main thread: wait up to this duration for marker. In practice found on first query (~90ms).
    private static let markerWait: TimeInterval = 1

    /// Fallback when marker cannot be found: only matches if exactly one terminal has matching working directory (dev servers often run in same directory). Returns nil if ambiguous.
    static func pick(_ terminals: [Terminal], cwd: String) -> String? {
        let sameDirectory = terminals.filter { trimmed($0.workingDirectory) == trimmed(cwd) }
        return sameDirectory.count == 1 ? sameDirectory[0].id : nil
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// OSC 2 escape sequence to set title. Title originates from Ghostty (trust boundary): strip control characters so escape sequences in original title are not replayed into terminal.
    static func titleSequence(_ title: String) -> [UInt8] {
        let clean = String(String.UnicodeScalarView(title.unicodeScalars.filter { $0.properties.generalCategory != .control }))
        return Array("\u{1B}]2;\(clean)\u{07}".utf8)
    }

    /// The tty capable of receiving marker writes: controlling terminal of `pid`, directly spawned by Ghostty (climbing up ppid, Ghostty's direct child shares the same tty).
    /// Nested inside tmux (tmux daemon parented by launchd) or nvim :terminal (tty spawned by nvim) returns nil: OSC 2 is consumed by them and cannot be restored.
    static func markableTTY(_ pid: Int32, ghostty: Set<Int32>, parent: (Int32) -> Int32?, tty: (Int32) -> String?) -> String? {
        guard let own = tty(pid) else { return nil }
        var current = pid
        // Process trees are shallow; limit depth to guard against invalid cycles in ppid.
        for _ in 0..<64 {
            guard let next = parent(current), next > 1 else { return nil }
            if ghostty.contains(next) { return tty(current) == own ? own : nil }
            current = next
        }
        return nil
    }

    /// Focus Ghostty and switch to window, tab, and split of this session; if unrecognizable, bring Ghostty to front.
    static func focus(_ terminal: TerminalRef) {
        let ghostty = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !ghostty.isEmpty else {
            // Not running: activate Ghostty without session.
            Apps.activate(bundleID)
            return
        }
        let ghosttyPIDs = Set(ghostty.map(\.processIdentifier))
        queue.async {
            let all = terminals()
            let target = all.flatMap { all in marked(terminal, ghostty: ghosttyPIDs, in: all) ?? pick(all, cwd: terminal.cwd) }
            // id originates from Ghostty; validate as UUID before embedding into script (trust boundary).
            let focus = target.flatMap { UUID(uuidString: $0) == nil ? nil : "focus terminal id \"\($0)\"\n" } ?? ""
            _ = execute("tell application id \"\(bundleID)\"\n\(timeout)\n\(focus)activate\nend timeout\nend tell")
        }
    }

    /// True if this terminal is currently focused right in front of user: Ghostty is frontmost, and the focused terminal in selected tab of front window matches it (following Ghostty `notify-on-command-finish = unfocused`).
    /// Evaluated strictly for this single terminal: other tabs, splits, or windows in same window do not qualify.
    /// When card arrives without user clicking: read id and working directory only, without reading title or writing marker (CLAUDE.md hard rule: title is read only upon click navigation).
    /// Therefore check process first (shell tty matches, directly spawned by Ghostty), then match by directory: focused terminal directory matches and is unique (`pick`);
    /// if two share same directory, terminal omits directory, or shell is outside Ghostty, pop up card as usual.
    /// Does not send Apple Event if Ghostty is not frontmost. `answer` called on internal queue.
    /// @see /Applications/Ghostty.app/Contents/Resources/Ghostty.sdef (tab's focused terminal)
    @MainActor
    static func isFocused(_ terminal: TerminalRef, answer: @escaping @Sendable (Bool) -> Void) {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleID else { return answer(false) }
        let ghosttyPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        queue.async {
            // Confirm shell runs in terminal directly spawned by Ghostty (not in VS Code, Terminal.app, tmux): otherwise other terminal in same directory may be mistaken for it.
            guard case .tty(let expected) = terminal.identity, tty(of: terminal.pid) == expected,
                  markableTTY(terminal.pid, ghostty: ghosttyPIDs, parent: { process($0)?.kp_eproc.e_ppid }, tty: tty(of:)) != nil
            else { return answer(false) }
            // Single Apple Event retrieves: { focused id, {id...}, {working directory...} }
            guard let result = execute("tell application id \"\(bundleID)\"\n\(timeout)\nget {id of focused terminal of selected tab of front window, id of every terminal, working directory of every terminal}\nend timeout\nend tell"),
                  result.numberOfItems == 3, let focused = result.atIndex(1)?.stringValue,
                  let ids = result.atIndex(2), let directories = result.atIndex(3)
            else { return answer(false) }
            let all = (0..<ids.numberOfItems).compactMap { i in
                // Title not read, leave empty.
                ids.atIndex(i + 1)?.stringValue.map { Terminal(id: $0, title: "", workingDirectory: directories.atIndex(i + 1)?.stringValue ?? "") }
            }
            // Terminals not reporting directory (missing shell integration) cannot be disambiguated: pop card as usual.
            answer(!all.contains { $0.workingDirectory.isEmpty } && pick(all, cwd: terminal.cwd) == focused)
        }
    }

    /// Writes a one-time title to session tty, observes which terminal in Ghostty adopts it, then restores original title.
    /// Ghostty AppleScript does not expose tty (1.3, nor on main branch yet); tty is the only unambiguous identifier.
    /// @see https://github.com/kovoor/claude-code-notifier (same approach: temporary title as marker, restored after match)
    private static func marked(_ terminal: TerminalRef, ghostty: Set<Int32>, in terminals: [Terminal]) -> String? {
        // Card holds snapshot: if process exited and PID reused by other terminal, do not write to that tty.
        let alive: Bool
        switch terminal.identity {
        case .started(let start): alive = AgentWatcher.isRunning(pid: terminal.pid, since: start)
        case .tty(let expected): alive = tty(of: terminal.pid) == expected
        }
        guard alive, let tty = markableTTY(terminal.pid, ghostty: ghostty, parent: { process($0)?.kp_eproc.e_ppid }, tty: tty(of:))
        else { return nil }
        let marker = "notchkeeper-\(UUID().uuidString)"
        guard write(titleSequence(marker), to: tty) else { return nil }
        let deadline = Date().addingTimeInterval(markerWait)
        repeat {
            // Stop waiting if Apple Event fails (execute logs error); empty list means not yet found.
            guard let ids = execute("tell application id \"\(bundleID)\"\n\(timeout)\nget id of every terminal whose name is \"\(marker)\"\nend timeout\nend tell")
            else { return nil }
            if let id = ids.atIndex(1)?.stringValue {
                // If not restored, Claude Code won't restore it: it only updates title on state transitions (empirically verified).
                // If Claude happens to transition status between reading title and restoration, restored title holds previous status glyph until next transition.
                let original = terminals.first { $0.id == id }
                // Terminal missing in snapshot (opened after snapshot taken) is also considered unrestored.
                if original.map({ !write(titleSequence($0.title), to: tty) }) ?? true {
                    Log.write("Ghostty: title could not be restored, holding on marker until Claude Code next updates title")
                }
                return id
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        // Timeout: Ghostty likely has fixed title or ignores OSC 2.
        // Or Ghostty was blocked >1s and marker arrived late: terminal remains on marker until Claude Code updates title.
        Log.write("Ghostty: tty marker not found, falling back to directory matching")
        return nil
    }

    /// nil if process does not exist. Use sysctl rather than proc_pidinfo: Ghostty's direct child is setuid root `/usr/bin/login`;
    /// proc_pidinfo reading other users' processes fails with EPERM, whereas sysctl succeeds (`ps` uses this).
    /// @see https://developer.apple.com/library/archive/qa/qa2004/qa1123.html
    private static func process(_ pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        // On non-existent process, call succeeds but size is 0.
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size else { return nil }
        return info
    }

    /// Process controlling terminal, e.g. `/dev/ttys006`; nil if process exited or has no controlling terminal.
    /// Uses `devname_r`: `devname` returns static buffer and is not thread-safe (man 3 devname).
    private static func tty(of pid: Int32) -> String? {
        guard let device = process(pid)?.kp_eproc.e_tdev, device != -1 else { return nil }  // NODEV: no controlling terminal
        var name = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard devname_r(device, S_IFCHR, &name, Int32(name.count)) != nil else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// Non-blocking single write: fails if Ghostty hangs or output buffer full, never blocking queue.
    /// Writes to terminal output display side, not claude stdin.
    private static func write(_ bytes: [UInt8], to tty: String) -> Bool {
        let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        // Partial write: append BEL to terminate OSC so terminal does not swallow subsequent Claude output as title.
        if written > 0, written < bytes.count { _ = Darwin.write(fd, [0x07], 1) }
        return written == bytes.count
    }

    /// All terminals; nil if Apple Event fails (user denied Ghostty automation, timeout).
    private static func terminals() -> [Terminal]? {
        // Result has three columns: { {id...}, {name...}, {working directory...} }
        guard let columns = execute("tell application id \"\(bundleID)\"\n\(timeout)\nget {id, name, working directory} of every terminal\nend timeout\nend tell"),
              columns.numberOfItems == 3,
              let ids = columns.atIndex(1), let titles = columns.atIndex(2), let directories = columns.atIndex(3) else { return nil }
        return (0..<ids.numberOfItems).compactMap { i in
            guard let id = ids.atIndex(i + 1)?.stringValue else { return nil }
            // Terminals without shell integration have missing value for directory.
            return Terminal(id: id, title: titles.atIndex(i + 1)?.stringValue ?? "",
                            workingDirectory: directories.atIndex(i + 1)?.stringValue ?? "")
        }
    }

    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let script = NSAppleScript(source: source) else { preconditionFailure("hardcoded script always compiles") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743: User denied Notchkeeper control of Ghostty (System Settings > Privacy & Security > Automation)
            Log.write("Ghostty: Apple Event failed (\(error[NSAppleScript.errorNumber] ?? "?"))")
            return nil
        }
        return result
    }
}
