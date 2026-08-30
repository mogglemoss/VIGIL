import Foundation

enum Log {
    private static let lock = NSLock()
    private static let start = Date()

    /// Launched from Finder there is no stdout to read, so everything also goes
    /// to a file. Otherwise the only account of a failed watch is the pilot's
    /// memory of it.
    /// O_APPEND rather than seek-to-end: a refused second instance writes to
    /// this same file while the standing watch is still ticking into it, and
    /// seeking is not atomic — the two mangle each other's lines.
    private static let file: Int32 = {
        guard isatty(STDOUT_FILENO) != 1 else { return -1 }
        guard let directory = FileManager.default.urls(for: .libraryDirectory,
                                                       in: .userDomainMask).first?
            .appendingPathComponent("Logs/VIGIL", isDirectory: true) else { return -1 }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("vigil.log").path
        return open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }()

    private static func mirror(_ line: String) {
        guard file >= 0 else { return }
        let text = line + "\n"
        _ = text.withCString { write(file, $0, strlen($0)) }
    }

    static var stamp: String {
        let t = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    private static func emit(_ mark: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "[\(stamp)] \(mark) \(message)"
        print(line)
        fflush(stdout)
        mirror(line)
    }

    static func info(_ m: String) { emit("·", m) }
    static func warn(_ m: String) { emit("!", m) }
    static func fail(_ m: String) { emit("✗", m) }
    static func good(_ m: String) { emit("✓", m) }

    /// Preflight / verdict blocks print raw so they read as a report.
    static func raw(_ m: String = "") {
        lock.lock(); defer { lock.unlock() }
        print(m); fflush(stdout); mirror(m)
    }
}
