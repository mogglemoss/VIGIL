import Foundation

/// One watch at a time.
///
/// Two instances is not a harmless duplicate. Both capture the display, which
/// costs real frame rate; both claim ⌥⌘S, and `RegisterEventHotKey` grants the
/// second registration without complaint, so a keypress goes to whichever the
/// window server feels like — you cannot tell which watch you just struck.
///
/// An advisory `flock` rather than a PID file: the kernel drops it when the
/// process dies, so a crash cannot leave a stale lock that keeps you out.
enum SingleInstance {

    private nonisolated(unsafe) static var descriptor: Int32 = -1

    struct Held {
        let pid: pid_t?
    }

    /// Returns nil when the lock is ours, or the holder when it is not.
    static func claim() -> Held? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask).first?
            .appendingPathComponent("VIGIL", isDirectory: true) else { return Held(pid: nil) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("watch.lock").path

        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }   // cannot lock; do not block the watch over it

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Someone holds it. They wrote their pid in; report it if readable.
            let held = (try? String(contentsOfFile: path, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            close(fd)
            return Held(pid: held)
        }

        ftruncate(fd, 0)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        descriptor = fd            // held open for the life of the process
        return nil
    }
}
