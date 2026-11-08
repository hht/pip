import Foundation
import Testing

/// A single zsh session: sets up `plugins/terminal/notchkeeper.zsh` and a mock `bin/pipctl` in temp dir (writing arguments per line to `calls/`).
/// Interactive zsh reads commands from stdin. Wraps with `script` under `pty` for terminal access and `$TTY`.
private struct Session {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-plugin-\(UUID().uuidString)")
    var calls: URL { root.appendingPathComponent("calls") }

    init() throws {
        let fm = FileManager.default
        let plugin = root.appendingPathComponent("plugins/terminal")
        try fm.createDirectory(at: plugin, withIntermediateDirectories: true)
        try fm.createDirectory(at: calls, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/plugins/terminal/notchkeeper.zsh")
        try fm.copyItem(at: source.standardized, to: plugin.appendingPathComponent("notchkeeper.zsh"))
        let pipctl = root.appendingPathComponent("bin/pipctl")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/../calls/$(date +%s%N)-$$\"\n".write(to: pipctl, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pipctl.path)
    }

    /// Run commands and wait until mock pipctl has been invoked `expecting` times, returning args for each call.
    func run(_ commands: [String], expecting: Int, pty: Bool = true) throws -> [[String]] {
        let script = (["notchkeeper_min_seconds=0.3", "source \(root.path)/plugins/terminal/notchkeeper.zsh"] + commands + ["exit"])
            .joined(separator: "\n") + "\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pty ? "/usr/bin/script" : "/bin/zsh")
        // Disable line editing (+Z): zle initialization drops input already written to terminal
        p.arguments = pty ? ["-q", "/dev/null", "/bin/zsh", "-fi", "+Z"] : ["-fi", "+Z"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        p.waitUntilExit()
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        var names: [String] = []
        repeat {
            names = try FileManager.default.contentsOfDirectory(atPath: calls.path).sorted()
            if names.count >= expecting { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        // Extra wait to allow unexpected calls to emerge
        Thread.sleep(forTimeInterval: 0.2)
        names = try FileManager.default.contentsOfDirectory(atPath: calls.path).sorted()
        defer { try? FileManager.default.removeItem(at: root) }  // Each session runs once
        return try names.map { try String(contentsOf: calls.appendingPathComponent($0), encoding: .utf8).split(separator: "\n").map(String.init) }
    }
}

private func value(_ args: [String], _ option: String) -> [String] {
    args.indices.filter { args[$0] == option && $0 + 1 < args.count }.map { args[$0 + 1] }
}

@Suite(.serialized) struct TerminalPlugin {
    @Test func failedLongCommand() throws {
        let s = try Session()
        let calls = try s.run(["sleep 0.4; false"], expecting: 1)
        try #require(calls.count == 1)
        let args = calls[0]
        #expect(args.first == "notify")
        #expect(value(args, "--plugin") == ["terminal"])
        #expect(value(args, "--title") == ["sleep failed"])
        #expect(value(args, "--outcome") == ["failed"])
        #expect(value(args, "--value") == ["0 s"])
        #expect(value(args, "--fact").first == "exit_code=1")
        #expect(value(args, "--fact").count == 2)
    }

    @Test func successfulLongCommand() throws {
        let s = try Session()
        let calls = try s.run(["sleep 0.4"], expecting: 1)
        try #require(calls.count == 1)
        #expect(value(calls[0], "--title") == ["sleep finished"])
        #expect(value(calls[0], "--outcome") == ["done"])
        #expect(value(calls[0], "--fact").first == "exit_code=0")
    }

    /// Short or ignored commands remain silent; final long command confirms hooks are running
    @Test func shortAndIgnoredCommandsStaySilent() throws {
        let s = try Session()
        let calls = try s.run(["true", "false", "vim() { sleep 0.4 }", "vim x", "sleep 0.4"], expecting: 1)
        #expect(calls.map { value($0, "--title") } == [["sleep finished"]])
    }

    /// Forwards command name only: arguments and environment variable assignments stay in shell
    @Test func onlyCommandNameLeavesShell() throws {
        let s = try Session()
        let calls = try s.run(["SECRET_TOKEN=abc env sleep 0.4 && echo password123"], expecting: 1)
        try #require(calls.count == 1)
        #expect(value(calls[0], "--title") == ["sleep finished"])
        #expect(!calls[0].joined(separator: " ").contains("abc"))
        #expect(!calls[0].joined(separator: " ").contains("password123"))
        #expect(!calls[0].joined(separator: " ").contains("0.4"))
    }

    /// Prefixes and valued options are skipped: option values are parameters and must not be treated as command names
    @Test(arguments: ["sudo -u alice sleep 0.4", "sudo -iu alice sleep 0.4", "sudo -ualice sleep 0.4", "sudo -uroot sleep 0.4",
                      "env -u FOO sleep 0.4", "nice -n 5 sleep 0.4", "( sleep 0.4 )", "{ sleep 0.4 }", "command sleep 0.4"])
    func prefixesSkipped(_ line: String) throws {
        let s = try Session()
        // Do not actually sudo in tests: mock function runs last two words
        let calls = try s.run(["sudo() { \"${@[-2,-1]}\" }", line], expecting: 1)
        #expect(calls.map { value($0, "--title") } == [["sleep finished"]])
    }

    /// User shell options do not leak into plugin: titles not split under shwordsplit, ignore list intact under ksharrays
    @Test func userOptionsDoNotLeakIn() throws {
        let s = try Session()
        let calls = try s.run(["setopt shwordsplit ksharrays", "vim() { sleep 0.4 }", "vim", "sleep 0.4"], expecting: 1)
        #expect(calls.map { value($0, "--title") } == [["sleep finished"]])
    }

    /// Terminal identity: same terminal shares group, click jumps back to it
    @Test func terminalIdentity() throws {
        let s = try Session()
        let calls = try s.run(["sleep 0.4"], expecting: 1, pty: true)
        try #require(calls.count == 1)
        let tty = value(calls[0], "--tty")
        #expect(tty.count == 1 && tty[0].hasPrefix("/dev/tty"))
        #expect(value(calls[0], "--group") == tty.map { "tty:" + $0 })
        #expect(value(calls[0], "--pid").count == 1 && Int32(value(calls[0], "--pid")[0]) != nil)
        #expect(value(calls[0], "--cwd").count == 1)
    }
}
