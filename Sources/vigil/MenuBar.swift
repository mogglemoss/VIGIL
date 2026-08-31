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
        var attached = false
        var clipping = false
        var heldSeconds = Double.zero
        var windowSeconds = Double.zero
        var clipSeconds = Double.zero
        var gigabytes = Double.zero
        var clipsSaved = 0
        var audioDescription = ""
        var audioAttached = true
        var lastClip: URL?
    }

    var readState: () -> State = { State() }
    var onToggleClip: () -> Void = {}
    var onSetLength: (Double) -> Void = { _ in }
    var onQuit: () -> Void = {}
    var onAbout: () -> Void = {}
    var onPreferences: () -> Void = {}
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
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "VIGIL")
        image?.isTemplate = true
        return image
    }

    /// Called from the ticker so the menu bar reflects the ring without anyone
    /// opening the menu.
    func refresh() {
        let state = readState()
        guard let button = statusItem?.button else { return }
        // Three states, three readings, same mark — swapping the glyph itself
        // would read as a different app.
        //
        //   waiting    dimmed, no clock      nothing is being held
        //   observing  normal, no clock      the ring is filling
        //   witnessing RED, with a clock     a record is open
        //
        // Red is drawn into the image rather than applied as a tint: a template
        // image takes the menu bar's own colour and cannot be made red.
        if state.clipping {
            button.image = MinistryMark.glyph(height: 15, color: Overlay.Ink.blood)
            button.title = " " + Self.clock(state.clipSeconds)
            button.appearsDisabled = false
        } else {
            button.image = MinistryMark.glyph(height: 15)
            button.title = ""
            button.appearsDisabled = !state.attached
        }
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
        let second: String
        if state.clipping {
            headline = "Witnessing · \(Self.clock(state.clipSeconds))"
            second = String(format: "%.2f GB in memory", state.gigabytes)
        } else if state.attached {
            headline = "Observing · \(Self.clock(state.heldSeconds)) of \(Self.clock(state.windowSeconds)) held"
            second = String(format: "%.2f GB in memory", state.gigabytes)
        } else if state.observing {
            // Standing, but with nothing to watch. Say so plainly: an idle
            // watch and a filling one must not look the same.
            headline = "Waiting for the EVE client"
            second = "Nothing is being held. The launcher does not count."
        } else {
            headline = "Starting"
            second = ""
        }
        menu.addItem(Self.disabled(headline))
        if !second.isEmpty { menu.addItem(Self.disabled(second)) }
        menu.addItem(Self.disabled(state.audioAttached
                                   ? "Audio · \(state.audioDescription)"
                                   : "Audio · awaiting \(state.audioDescription)"))
        menu.addItem(.separator())

        let action = NSMenuItem(
            title: state.clipping ? "Stop and file the clip" : "Enter into the record",
            action: #selector(toggleClip), keyEquivalent: "")
        action.target = self
        action.isEnabled = state.attached
        menu.addItem(action)
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

        let prefs = NSMenuItem(title: "Standing Orders…", action: #selector(showPreferences),
                               keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let about = NSMenuItem(title: "About VIGIL", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit VIGIL", action: #selector(quit), keyEquivalent: "q")
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
    @objc private func showAbout() { onAbout() }
    @objc private func showPreferences() { onPreferences() }
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
