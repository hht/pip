import Testing
@testable import Notchkeeper

private func terminal(_ id: String, _ dir: String) -> Ghostty.Terminal {
    Ghostty.Terminal(id: id, title: "zsh", workingDirectory: dir)
}

/// docs/agent-integration.md "Jumping to Ghostty": falls back to directory matching when marker cannot be found; only unique matches qualify.
@Suite struct GhosttyDirectoryFallback {
    private let terminals = [terminal("A", "/Users/u/p1"), terminal("B", "/Users/u/p2"), terminal("C", "/Users/u/p2")]

    @Test func uniqueDirectoryWins() {
        #expect(Ghostty.pick(terminals, cwd: "/Users/u/p1") == "A")
    }

    /// Ambiguous if dev server or other instances share directory: does not guess.
    @Test func sameDirectoryIsAmbiguous() {
        #expect(Ghostty.pick(terminals, cwd: "/Users/u/p2") == nil)
    }

    @Test func noDirectoryIsNil() {
        #expect(Ghostty.pick(terminals, cwd: "/elsewhere") == nil)
    }

    @Test func trailingSlashIsTheSameDirectory() {
        #expect(Ghostty.pick([terminal("A", "/Users/u/p1/")], cwd: "/Users/u/p1") == "A")
    }
}

/// Titles written back to tty originate from Ghostty (trust boundary): strip control characters to avoid replaying embedded escape sequences.
@Suite struct GhosttyTitleSequence {
    @Test func wrapsTitleInOSC2() {
        #expect(Ghostty.titleSequence("✳ Fix login") == Array("\u{1B}]2;✳ Fix login\u{07}".utf8))
    }

    @Test func stripsControlCharacters() {
        #expect(Ghostty.titleSequence("a\u{1B}]0;x\u{07}b\u{9C}c\u{7F}\n") == Array("\u{1B}]2;a]0;xbc\u{07}".utf8))
    }
}

/// Only write markers when claude runs directly inside Ghostty: nested inside tmux or nvim :terminal, OSC 2 is consumed and cannot be restored.
@Suite struct GhosttyAncestry {
    private struct Proc { var parent: Int32; var tty: String? }
    /// claude 100 -> zsh 90 -> login 80 -> Ghostty 70; tmux: claude 200 -> zsh 190 -> tmux 180 -> launchd 1;
    /// nvim :terminal: claude 300 (ttys9) -> zsh 290 (ttys9) -> nvim 280 (ttys1) -> zsh 270 -> login 260 (ttys1) -> Ghostty 70
    private let procs: [Int32: Proc] = [
        100: Proc(parent: 90, tty: "/dev/ttys1"), 90: Proc(parent: 80, tty: "/dev/ttys1"), 80: Proc(parent: 70, tty: "/dev/ttys1"),
        200: Proc(parent: 190, tty: "/dev/ttys2"), 190: Proc(parent: 180, tty: "/dev/ttys2"), 180: Proc(parent: 1, tty: nil),
        300: Proc(parent: 290, tty: "/dev/ttys9"), 290: Proc(parent: 280, tty: "/dev/ttys9"), 280: Proc(parent: 270, tty: "/dev/ttys3"),
        270: Proc(parent: 260, tty: "/dev/ttys3"), 260: Proc(parent: 70, tty: "/dev/ttys3"),
    ]

    private func tty(_ pid: Int32) -> String? {
        Ghostty.markableTTY(pid, ghostty: [70], parent: { procs[$0]?.parent }, tty: { procs[$0]?.tty })
    }

    @Test func directlyInGhostty() {
        #expect(tty(100) == "/dev/ttys1")
    }

    @Test func insideTmuxIsNot() {
        #expect(tty(200) == nil)
    }

    /// Ghostty exists in ancestors, but claude's tty was opened by nvim, not Ghostty.
    @Test func insideNestedTerminalIsNot() {
        #expect(tty(300) == nil)
    }

    /// Ghostty configured with `command = claude`: claude itself is direct child of Ghostty.
    @Test func claudeIsGhosttysChild() {
        #expect(Ghostty.markableTTY(500, ghostty: [70], parent: { $0 == 500 ? 70 : nil }, tty: { $0 == 500 ? "/dev/ttys5" : nil }) == "/dev/ttys5")
    }

    @Test func noControllingTerminalIsNot() {
        #expect(Ghostty.markableTTY(600, ghostty: [70], parent: { $0 == 600 ? 70 : nil }, tty: { _ in nil }) == nil)
    }

    /// Process vanished midway (parent cannot be inspected).
    @Test func vanishedProcessIsNot() {
        #expect(tty(400) == nil)
    }
}
