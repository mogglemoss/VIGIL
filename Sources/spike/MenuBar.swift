import AppKit

/// The status item. `.accessory` activation means no dock icon and no menu of
/// our own in the menu bar proper, so this is the only way to reach the app
/// without a hotkey — and the only way to quit it if the terminal is gone.
///
/// The menu is rebuilt every time it opens rather than mutated in place: the
/// state it reports is read at the moment you look at it, so it cannot go
/// stale between ticks.
final class MenuBar: NSObject, NSMenuDelegate {

    struct State {
        var observing = false
        var clipping = false
        var heldSeconds = Double.zero
        var windowSeconds = Double.zero
        var clipSeconds = Double.zero
        var gigabytes = Double.zero
        var clipsSaved = 0
        var audioDescription = ""
        var lastClip: URL?
    }

    var readState: () -> State = { State() }
    var onToggleClip: () -> Void = {}
    var onSetLength: (Double) -> Void = { _ in }
    var onQuit: () -> Void = {}
    var clipsDirectory: URL?

    private var statusItem: NSStatusItem?

    private static let lengths: [(String, Double)] = [
        ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60),
        ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600),
        ("15 minutes", 900)
    ]

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MinistryMark.glyph(height: 15)
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Observance")
        image?.isTemplate = true
        return image
    }

    /// Called from the ticker so the menu bar reflects the ring without anyone
    /// opening the menu.
    func refresh() {
        let state = readState()
        guard let button = statusItem?.button else { return }
        // The glyph stays put; the clock beside it is what changes. Swapping
        // the mark itself would read as a different app.
        button.image = MinistryMark.glyph(height: 15)
        button.title = state.clipping ? " " + Self.clock(state.clipSeconds) : ""
        button.contentTintColor = state.clipping ? Overlay.Ink.bright : nil
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let state = readState()
        menu.removeAllItems()

        let headline: String
        if state.clipping {
            headline = "Witnessing · \(Self.clock(state.clipSeconds))"
        } else if state.observing {
            headline = "Observing · \(Self.clock(state.heldSeconds)) of \(Self.clock(state.windowSeconds)) held"
        } else {
            headline = "Starting"
        }
        menu.addItem(Self.disabled(headline))
        menu.addItem(Self.disabled(String(format: "%.2f GB in memory · %@",
                                          state.gigabytes, state.audioDescription)))
        menu.addItem(.separator())

        let action = NSMenuItem(
            title: state.clipping ? "Stop and file the clip" : "Enter into the record",
            action: #selector(toggleClip), keyEquivalent: "s")
        action.keyEquivalentModifierMask = [.option, .command]
        action.target = self
        action.isEnabled = state.observing
        menu.addItem(action)
        menu.addItem(.separator())

        let lengthItem = NSMenuItem(title: "Replay length", action: nil, keyEquivalent: "")
        let lengths = NSMenu()
        for (title, seconds) in Self.lengths {
            let entry = NSMenuItem(title: title, action: #selector(setLength(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = Int(seconds)
            entry.state = abs(state.windowSeconds - seconds) < 0.5 ? .on : .off
            lengths.addItem(entry)
        }
        lengthItem.submenu = lengths
        menu.addItem(lengthItem)
        menu.addItem(.separator())

        let reveal = NSMenuItem(title: "Open clips folder",
                                action: #selector(openClips), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        if let last = state.lastClip {
            let item = NSMenuItem(title: "Reveal \(last.lastPathComponent)",
                                  action: #selector(revealLast), keyEquivalent: "")
            item.target = self
            item.representedObject = last
            menu.addItem(item)
        }
        menu.addItem(Self.disabled("\(state.clipsSaved) filed this session"))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Observance", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.option, .command]
        quit.target = self
        menu.addItem(quit)
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleClip() { onToggleClip() }
    @objc private func quit() { onQuit() }
    @objc private func setLength(_ sender: NSMenuItem) { onSetLength(Double(sender.tag)) }

    @objc private func openClips() {
        guard let clipsDirectory else { return }
        NSWorkspace.shared.open(clipsDirectory)
    }

    @objc private func revealLast(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
