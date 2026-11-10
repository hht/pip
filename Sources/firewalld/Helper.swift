import Darwin
import Foundation
import FirewallCore
import os

/// Answers: how a round and a command execute in detail — acquire lock, read state, invoke pfctl according to actions
/// prescribed by `FirewallState`, record results, and write two files.
/// Does not decide policy (in FirewallCore); agnostic of caller (launchd or osascript).
enum Helper {
    enum Command: Equatable {
        /// `clash` is Clash Verge directory, snapshotted upon enabling
        case enable(clash: URL)
        case keep, disable
    }

    enum Failure: Error, Equatable {
        case command(FirewallCommandError)
        /// Firewall state file unreadable: do not overwrite (keep original for inspection), run rescue script first
        case stateUnreadable
        case snapshot(SnapshotFailure)
        case busy
        case io(String)
    }

    /// LaunchDaemon startup arguments: tunnel interface name, rules scope to load
    struct RoundConfig: Equatable {
        let tunnel: String
        let scope: FirewallRules.Scope
        let rules: FirewallRules

        init?(tunnel: String, scope: FirewallRules.Scope) {
            guard let rules = FirewallRules(tunnel: tunnel, scope: scope, directory: FirewallPaths.directory.path) else { return nil }
            (self.tunnel, self.scope, self.rules) = (tunnel, scope, rules)
        }
    }

    static let log = Logger(subsystem: FirewallPaths.label, category: "helper")

    /// One round (docs/firewall.md §4 "LaunchDaemon Rounds"). Returns `nil` if lock not acquired, doing nothing until next round
    static func round(_ sys: FirewallSystem, _ config: RoundConfig) -> FirewallStatus? {
        locked(sys) { () -> FirewallStatus in
            let moment = sys.moment()
            let stateURL = sys.directory.appendingPathComponent(FirewallState.fileName)
            let restored = restore(stateURL)
            var state = FirewallState(bootSession: moment.bootSession)
            if case .valid(let s) = restored { state = s }
            // Do not overwrite unreadable state file: treat as off, leave original for diagnosis
            let writable = restored != .unreadable
            func save() -> Bool {
                guard writable else { return false }
                do {
                    try AtomicFile.write(state.encoded(), to: stateURL, mode: 0o600)
                    return true
                } catch {
                    log.error("Failed to write firewall state file: \(error, privacy: .public)")
                    return false
                }
            }
            let pf = { (args: [String], input: String?) in sys.run("/sbin/pfctl", args, input) }

            let references = { () -> Set<String>? in
                let out = pf(["-s", "References"], nil)
                return out.succeeded ? PFOutput.tokens(fromReferences: out.stdout) : nil
            }

            let anchor = pf(["-a", FirewallPaths.anchor, "-sr"], nil)
            let snapshot = PFSnapshot(anchorEmpty: anchor.succeeded && anchor.stdout.allSatisfy(\.isWhitespace), tokens: references())
            var actions = state.tick(at: moment, pf: snapshot, rules: config.rules)
            var failed: [PFStep] = []
            // Ensure state file is writable first: if unwritable, acquired token cannot be recorded, leading to unbounded token growth via -E
            if !save(), actions.contains(.enable) {
                actions.removeAll { $0 == .enable }
                failed.append(.enable)
            }
            for action in actions {
                let out = switch action {
                case .load(let r): pf(["-a", FirewallPaths.anchor, "-f", "-"], r.text)
                case .enable: pf(["-E"], nil)
                case .flush: pf(["-a", FirewallPaths.anchor, "-F", "rules"], nil)
                case .release(let token): pf(["-X", token], nil)
                }
                guard out.succeeded else {
                    log.error("pfctl \(action.step.rawValue, privacy: .public) failed (\(out.status)): \(out.stderr, privacy: .public)")
                    failed.append(action.step)
                    continue
                }
                state.record(action, token: action == .enable ? PFOutput.token(fromEnable: out.stderr) : nil)
                _ = save() // Persist immediately on each success: crash after token acquisition (including bootout) leaves token known to next round and rescue script
                if action == .enable {
                    state.confirmReference(liveTokens: references())
                    _ = save()
                }
            }

            var check: FirewallCheck?
            if state.mode != .off {
                // Pass empty string on read failure; corresponding check item fails
                let stdout = { (out: Output) in out.succeeded ? out.stdout : "" }
                check = state.check(mainRules: stdout(pf(["-sr"], nil)),
                                    anchorRules: stdout(pf(["-a", FirewallPaths.anchor, "-vsr"], nil)),
                                    info: stdout(pf(["-s", "info"], nil)),
                                    interfaces: stdout(sys.run("/sbin/ifconfig", ["-l"], nil)), tunnel: config.tunnel)
            }
            _ = save()

            let now = sys.now()
            // If rule replacement fails in this round, anchor still has old rules; do not attribute to this round
            var status = FirewallStatus(mode: .off, scope: state.loadedRules == config.rules ? config.scope : nil, check: check,
                                        failedSteps: failed, checkedAt: now)
            switch state.mode {
            case .off: status.mode = writable ? .off : .stateUnreadable
            case .trial(let deadline):
                status.mode = .trial
                status.trialEndsAt = now.addingTimeInterval(TimeInterval(deadline.milliseconds - moment.now.milliseconds) / 1000)
            case .on: status.mode = .on
            }
            do {
                try AtomicFile.write(status.encoded(), to: sys.directory.appendingPathComponent(FirewallStatus.fileName), mode: 0o644)
            } catch {
                log.error("Failed to write status summary: \(error, privacy: .public)")
            }
            return status
        }
    }

    /// enable / keep / disable: modifies files only (enable also snapshots allow tables first), then kicks daemon to run an immediate round.
    /// Actions on pf are decided solely inside a round.
    /// enable returns the two snapshotted tables (printed on CLI for human verification); others return `nil`.
    @discardableResult
    static func command(_ command: Command, _ sys: FirewallSystem) throws(Failure) -> AllowTables? {
        // Taking snapshot reads files and queries DNS, executed outside lock; written only if enable succeeds
        var tables: AllowTables?
        if case .enable(let clash) = command {
            do { tables = try AllowTables.take(from: clash, sys) } catch { throw .snapshot(error) }
        }
        let done: Void? = try locked(sys) { () throws(Failure) in
            let moment = sys.moment()
            let stateURL = sys.directory.appendingPathComponent(FirewallState.fileName)
            var state = FirewallState(bootSession: moment.bootSession)
            switch restore(stateURL) {
            case .valid(let s): state = s
            case .missing: break
            // Corrupt file is not overwritten. disable still succeeds: each round treats unreadable state as off anyway
            case .unreadable: if command == .disable { return } else { throw .stateUnreadable }
            }
            do throws(FirewallCommandError) {
                switch command {
                case .enable: try state.enable(at: moment)
                case .keep: try state.keep(at: moment)
                case .disable: state.disable()
                }
            } catch {
                throw .command(error)
            }
            // Write tables before state: when daemon sees trial, required tables are already present
            do { try tables?.write(to: sys.directory) } catch { throw .io("Failed to write allow tables: \(error)") }
            do { try AtomicFile.write(state.encoded(), to: stateURL, mode: 0o600) } catch { throw .io("Failed to write firewall state file: \(error)") }
            // Restart daemon while still holding lock: it cannot be mid-round right now (rounds require this lock too),
            // so killing will not interrupt between pfctl -E and disk flush.
            // Newly spawned daemon runs a round once lock acquired; when off, daemon was not running, so this brings it up
            let kick = sys.run("/bin/launchctl", ["kickstart", "-k", "system/\(FirewallPaths.label)"], nil)
            guard kick.succeeded else { throw .io("State changed, but failed to kick daemon into immediate round (\(kick.stderr))") }
        }
        guard done != nil else { throw .busy }
        return tables
    }

    /// Daemon: round after round, with `pause` (sleep 10s in practice) between rounds;
    /// returns only after returning to off and successfully flushing rules in that round; no polling when off (docs/firewall.md §2).
    /// Continues running if flush fails: nobody else flushes after exit, leaving host-wide block rule hanging.
    /// Release failure ignored: an extra reference does not break internet access, running every 10s for it would constitute polling while off;
    /// next enable or rescue script handles it. A round that fails to acquire lock does not count, waits for next round as usual
    static func serve(_ sys: FirewallSystem, _ config: RoundConfig, pause: () -> Void) {
        while true {
            if let status = round(sys, config), status.mode == .off || status.mode == .stateUnreadable,
               !status.failedSteps.contains(.flush) { return }
            pause()
        }
    }

    private static func restore(_ url: URL) -> FirewallState.Restored {
        do {
            return FirewallState.restore(from: try Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            log.error("Cannot read firewall state file: \(error, privacy: .public)")
            return .unreadable
        }
    }

    /// Rounds and commands are mutually exclusive. Lock file root 0600: non-root users cannot open or hold it.
    /// Returns `nil` if lock not acquired within `sys.lockTimeout`; lock released automatically on process exit.
    /// If lock file cannot be opened (directory missing), proceeds unlocked: concurrent runner can only be another root round or command,
    /// preferable to skipping rounds or failing trial rollback
    private static func locked<T, E: Error>(_ sys: FirewallSystem, _ body: () throws(E) -> T) throws(E) -> T? {
        let fd = open(sys.directory.appendingPathComponent(FirewallPaths.lockFile).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0 {
            // Wait using monotonic clock: not stuck indefinitely if system clock is stepped backward
            let deadline = ContinuousClock.now + .seconds(sys.lockTimeout)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard ContinuousClock.now < deadline else {
                    log.error("Timed out waiting \(Int(sys.lockTimeout))s for lock")
                    return nil
                }
                usleep(100_000)
            }
        } else {
            log.error("Cannot open lock file (\(errno)), proceeding unlocked")
        }
        return try body()
    }
}
