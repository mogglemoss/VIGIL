import Foundation

enum Log {
    private static let lock = NSLock()
    private static let start = Date()

    static var stamp: String {
        let t = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    private static func emit(_ mark: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        print("[\(stamp)] \(mark) \(message)")
        fflush(stdout)
    }

    static func info(_ m: String) { emit("·", m) }
    static func warn(_ m: String) { emit("!", m) }
    static func fail(_ m: String) { emit("✗", m) }
    static func good(_ m: String) { emit("✓", m) }

    /// Preflight / verdict blocks print raw so they read as a report.
    static func raw(_ m: String = "") {
        lock.lock(); defer { lock.unlock() }
        print(m); fflush(stdout)
    }
}
