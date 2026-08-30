import AppKit

/// Making failure visible to someone who did not launch from a terminal.
///
/// VIGIL is an agent app with no window, so a double-clicked bundle has nowhere
/// to put a message: stdout goes to a void, and the process exits looking like
/// it simply declined to start. Anything that stops the watch, or that makes it
/// keep running while doing nothing useful, has to reach the screen.
enum Notify {

    /// Attached to a terminal? Then the terminal is the right place, and a
    /// modal dialog would be an interruption rather than a service.
    static var hasTerminal: Bool { isatty(STDOUT_FILENO) == 1 }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    /// The watch cannot stand. Always logged; shown when there is no terminal.
    static func fatal(_ title: String, _ message: String) {
        Log.fail(title)
        Log.raw(message)
        guard !hasTerminal else { return }
        onMain {
            NSApp.setActivationPolicy(.regular)   // so the dialog can come forward
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Close")
            alert.runModal()
        }
    }

    /// The watch is standing but something is wrong with it — a denied audio
    /// grant, most often. Shown once, then left to the overlay.
    private nonisolated(unsafe) static var warned = Set<String>()

    static func onceIfSilent(_ key: String, title: String, message: String) {
        Log.warn(title)
        guard !hasTerminal, !warned.contains(key) else { return }
        warned.insert(key)
        onMain {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Continue")
            alert.runModal()
        }
    }
}
