import Darwin
import Foundation

/// Ensures only a single instance per user: a second instance exits before creating NSApplication or drawing anything.
/// Uses a per-user exclusive flock (man 2 flock): arbitrated by the kernel, guaranteeing only one wins during concurrent launches;
/// automatically released on exit or crash without leaving orphaned lock files.
/// Stored in per-user private directory (confstr _CS_DARWIN_USER_DIR, 0700).
/// Does not use Info.plist's LSMultipleInstancesProhibited: that governs "multiple users launching simultaneously", not a second instance by the same user.
/// @see https://developer.apple.com/documentation/bundleresources/information-property-list/lsmultipleinstancesprohibited
@MainActor
enum SingleInstance {
    /// Held lock file descriptor, released by kernel when process terminates
    private static var heldLock: Int32?

    /// Called first thing during launch; false indicates another instance is already running and this process should exit.
    /// If lock unavailable (directory inaccessible or cannot open), launches normally and logs a warning.
    static func claim() -> Bool {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 else {
            Log.write("Single-instance lock unavailable: cannot get per-user private directory")
            return true
        }
        let url = URL(fileURLWithPath: String(cString: buf), isDirectory: true).appendingPathComponent("local.hht.notchkeeper.lock")
        // O_CLOEXEC: child processes do not inherit lock, preventing spawned processes from holding it after App exits
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            Log.write("Single-instance lock unavailable: \(String(cString: strerror(errno)))")
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            heldLock = fd
            return true
        }
        let err = errno
        close(fd)
        guard err == EWOULDBLOCK else {
            Log.write("Single-instance lock unavailable: \(String(cString: strerror(err)))")
            return true
        }
        Log.write("Another Notchkeeper instance holds the lock; this instance will exit")
        return false
    }
}
