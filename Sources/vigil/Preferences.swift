import AppKit
import Carbon.HIToolbox

/// A field that swallows one chord and reports it.
///
/// Rebinding needs a real key capture, which a menu cannot do — you have to
/// take over the responder chain, catch the raw event, and refuse anything that
/// would fire while the pilot is typing in local.
final class ChordField: NSView {

    var onChord: ((UInt32, UInt32, String) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var listening = false

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, current: String) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (frame.height - 18) / 2, width: frame.width, height: 18)
        addSubview(label)
        show(current)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func show(_ text: String) {
        // The system face, not the house monospace: ⌘ ⌥ ⌃ ⇧ have proper metrics
        // there and collide into each other anywhere else.
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: listening ? Overlay.Ink.bright : Overlay.Ink.bone,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle(); p.alignment = .center; return p
            }()
        ])
        layer?.borderColor = (listening ? Overlay.Ink.bright : Overlay.Ink.line).cgColor
        layer?.backgroundColor = NSColor(srgbRed: 0.102, green: 0.090, blue: 0.078,
                                         alpha: 1).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        listening = true
        show("press a chord…")
    }

    override func resignFirstResponder() -> Bool {
        if listening { listening = false; show(Settings.recordHotKey.label) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard listening else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) {
            listening = false
            show(Settings.recordHotKey.label)
            window?.makeFirstResponder(nil)
            return
        }
        let modifiers = Settings.carbonModifiers(from: event.modifierFlags)
        guard Settings.isUsable(modifiers: modifiers) else {
            show("needs ⌘, ⌥ or ⌃")
            return
        }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !key.isEmpty else { return }
        listening = false
        let text = Settings.label(modifiers: modifiers, key: key)
        show(text)
        window?.makeFirstResponder(nil)
        onChord?(UInt32(event.keyCode), modifiers, text)
    }
}

/// The office's preferences. Ink, micro-caps, and only the things a pilot
/// actually needs to override.
final class Preferences: NSObject, NSWindowDelegate, @unchecked Sendable {

    private var window: NSWindow?
    private static let size = NSSize(width: 470, height: 554)

    /// Applied immediately.
    var onHotKeyChanged: ((Settings.HotKey) -> Bool)?   // returns false if refused
    var onLengthChanged: ((Double) -> Void)?
    var onFolderChanged: ((URL) -> Void)?
    /// Cannot be applied to a running watch; the sheet says so.
    var onRestartNeeded: (() -> Void)?

    private var folderLabel: NSTextField?
    private var noteLabel: NSTextField?
    private var loginBox: NSButton?

    private static func mono(_ pt: CGFloat) -> NSFont {
        NSFont(name: "GeistMono-Medium", size: pt)
            ?? NSFont.monospacedSystemFont(ofSize: pt, weight: .medium)
    }

    private static func caps(_ text: String, _ pt: CGFloat, _ color: NSColor,
                             _ alignment: NSTextAlignment = .left) -> NSAttributedString {
        let p = NSMutableParagraphStyle(); p.alignment = alignment
        return NSAttributedString(string: text.uppercased(), attributes: [
            .font: mono(pt), .kern: pt * 0.16, .foregroundColor: color, .paragraphStyle: p])
    }

    private func row(_ title: String, y: CGFloat, in view: NSView) {
        let field = NSTextField(labelWithAttributedString:
            Self.caps(title, 9, Overlay.Ink.dim))
        field.frame = NSRect(x: 32, y: y, width: 150, height: 16)
        view.addSubview(field)
    }

    private func popup(_ items: [String], selected: Int, y: CGFloat,
                       action: Selector) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 190, y: y - 4, width: 238, height: 24))
        button.addItems(withTitles: items)
        button.selectItem(at: min(selected, max(0, items.count - 1)))
        button.target = self
        button.action = action
        button.font = Self.mono(11)
        return button
    }

    private static let lengthChoices: [(String, Double)] = [
        ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120),
        ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900)
    ]
    private static let capChoices: [(String, Double)] = [
        ("2 GB", 2), ("4 GB", 4), ("8 GB", 8), ("12 GB", 12), ("16 GB", 16)
    ]
    private static let scaleChoices: [(String, Double)] = [
        ("Native — sharpest, biggest", 1.0),
        ("Three quarters", 0.75),
        ("Half — cheapest", 0.5)
    ]
    private static let fpsChoices: [(String, Int32)] = [("60 fps", 60), ("30 fps", 30)]
    private static let captureChoices = ["EVE's window only", "The whole display"]

    func build() -> NSWindow {
        let size = Self.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "VIGIL — Standing Orders"
        // AppKit releases a programmatically-created window when it closes, and
        // we hold a strong reference to it as well. Leaving this true means
        // closing the sheet releases it twice and the app dies inside the close
        // animation. Overlay had this right; these two did not.
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Overlay.Ink.ground.withAlphaComponent(1)
        window.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = Overlay.Ink.ground.withAlphaComponent(1).cgColor

        let heading = NSTextField(labelWithAttributedString:
            Self.caps("Standing orders", 11, Overlay.Ink.rust))
        heading.frame = NSRect(x: 32, y: size.height - 54, width: 300, height: 18)
        content.addSubview(heading)

        // One cursor down the sheet, so adding an order is one block, not a
        // recalculation of every y below it.
        var y = size.height - 96
        let step: CGFloat = 40

        // ── standing at login ────────────────────────────────────────────────
        row("Stand at login", y: y, in: content)
        let login = NSButton(checkboxWithTitle: "  Start VIGIL when I log in",
                             target: self, action: #selector(setLogin(_:)))
        login.frame = NSRect(x: 196, y: y - 3, width: 250, height: 20)
        login.font = Self.mono(11)
        switch LoginItem.state {
        case .on: login.state = .on
        case .needsApproval:
            login.state = .on
            login.title = "  Awaiting your approval"
        case .off: login.state = .off
        case .unavailable: login.state = .off; login.isEnabled = false
        }
        content.addSubview(login)
        loginBox = login
        y -= step

        // ── the chord ────────────────────────────────────────────────────────
        row("Strike the record", y: y, in: content)
        let chord = ChordField(frame: NSRect(x: 200, y: y - 6, width: 130, height: 26),
                               current: Settings.recordHotKey.label)
        chord.onChord = { [weak self] code, mods, text in
            let previous = Settings.recordHotKey
            let candidate = Settings.HotKey(keyCode: code, modifiers: mods, label: text)
            if self?.onHotKeyChanged?(candidate) == true {
                Settings.recordHotKey = candidate
                self?.note("Bound to \(text). The same chord closes the clip.")
            } else {
                self?.note("\(text) is already spoken for — kept \(previous.label). Try another.")
            }
        }
        content.addSubview(chord)
        y -= step

        // ── the folder ───────────────────────────────────────────────────────
        row("Clips folder", y: y, in: content)
        let path = NSTextField(labelWithString: "")
        path.frame = NSRect(x: 200, y: y, width: 156, height: 16)
        path.lineBreakMode = .byTruncatingHead
        content.addSubview(path)
        folderLabel = path
        showFolder()
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        choose.frame = NSRect(x: 360, y: y - 6, width: 78, height: 26)
        choose.bezelStyle = .rounded
        choose.font = Self.mono(11)
        content.addSubview(choose)
        y -= step

        // ── the watch ────────────────────────────────────────────────────────
        row("Replay length", y: y, in: content)
        content.addSubview(popup(Self.lengthChoices.map(\.0),
                                 selected: Self.lengthChoices.firstIndex {
                                     abs($0.1 - Settings.length) < 0.5 } ?? 4,
                                 y: y, action: #selector(setLength(_:))))
        y -= step

        row("Memory ceiling", y: y, in: content)
        content.addSubview(popup(Self.capChoices.map(\.0),
                                 selected: Self.capChoices.firstIndex {
                                     abs($0.1 - Settings.capGB) < 0.01 } ?? 2,
                                 y: y, action: #selector(setCap(_:))))
        y -= step

        row("Capture", y: y, in: content)
        content.addSubview(popup(Self.captureChoices,
                                 selected: Settings.capturePreset == "display" ? 1 : 0,
                                 y: y, action: #selector(setCapture(_:))))
        y -= step

        row("Audio", y: y, in: content)
        content.addSubview(popup(["Game only", "Game and Discord", "Everything the Mac plays"],
                                 selected: ["game", "custom", "all"]
                                     .firstIndex(of: Settings.audioPreset) ?? 0,
                                 y: y, action: #selector(setAudio(_:))))
        y -= step

        row("Capture size", y: y, in: content)
        content.addSubview(popup(Self.scaleChoices.map(\.0),
                                 selected: Self.scaleChoices.firstIndex {
                                     abs($0.1 - Settings.scale) < 0.01 } ?? 0,
                                 y: y, action: #selector(setScale(_:))))
        y -= step

        row("Frame rate", y: y, in: content)
        content.addSubview(popup(Self.fpsChoices.map(\.0),
                                 selected: Settings.fps <= 30 ? 1 : 0,
                                 y: y, action: #selector(setFPS(_:))))
        y -= step

        row("Codec", y: y, in: content)
        content.addSubview(popup(["HEVC — smaller files", "H.264 — friendlier to editors"],
                                 selected: Settings.codec == "h264" ? 1 : 0,
                                 y: y, action: #selector(setCodec(_:))))

        // ── the note ─────────────────────────────────────────────────────────
        let note = NSTextField(labelWithString: "")
        note.frame = NSRect(x: 32, y: 22, width: size.width - 64, height: 34)
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        content.addSubview(note)
        noteLabel = note
        self.note("The chord and the folder take effect at once. Everything else "
                  + "takes effect when the watch next stands.")

        window.contentView = content
        return window
    }

    private func note(_ text: String) {
        noteLabel?.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "Geist-Regular", size: 11) ?? NSFont.systemFont(ofSize: 11),
            .foregroundColor: Overlay.Ink.dim,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineSpacing = 2; return p }()
        ])
    }

    private func showFolder() {
        folderLabel?.attributedStringValue = NSAttributedString(
            string: Settings.outputDirectory.lastPathComponent,
            attributes: [.font: Self.mono(11), .foregroundColor: Overlay.Ink.bone])
        folderLabel?.toolTip = Settings.outputDirectory.path
    }

    // MARK: - Actions

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.outputDirectory
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.outputDirectory = url
        showFolder()
        onFolderChanged?(url)
        note("Clips will be filed to \(url.path).")
    }

    @objc private func setLength(_ sender: NSPopUpButton) {
        let seconds = Self.lengthChoices[sender.indexOfSelectedItem].1
        Settings.length = seconds
        onLengthChanged?(seconds)
        note("The watch now holds \(Int(seconds)) seconds.")
    }

    @objc private func setAudio(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1:
            Settings.audioPreset = "custom"
            Settings.audioNames = ["EVE.app", "com.hnc.Discord"]
        case 2: Settings.audioPreset = "all"
        default: Settings.audioPreset = "game"
        }
        onRestartNeeded?()
        note("Audio changes when the watch next stands. Quit and start it again.")
    }

    @objc private func setLogin(_ sender: NSButton) {
        let wanted = sender.state == .on
        if wanted && !LoginItem.isInstalledProperly {
            sender.state = .off
            note("Move VIGIL to your Applications folder first. Registering a copy "
                 + "that lives elsewhere works until that folder is cleaned.")
            return
        }
        if let why = LoginItem.set(wanted) {
            sender.state = wanted ? .off : .on
            note("Could not change that: \(why)")
            return
        }
        switch LoginItem.state {
        case .needsApproval:
            note("Registered. macOS wants you to approve it in System Settings › "
                 + "General › Login Items.")
        case .on:
            note("VIGIL will stand at login, and attach itself when EVE appears.")
        default:
            note("VIGIL will no longer start at login.")
        }
    }

    @objc private func setCapture(_ sender: NSPopUpButton) {
        let display = sender.indexOfSelectedItem == 1
        Settings.capturePreset = display ? "display" : "game"
        onRestartNeeded?()
        note(display
             ? "The whole display will be recorded — everything in front of you, "
               + "not only EVE. Takes effect when the watch next stands."
             : "Only EVE's window will be recorded. Takes effect when the watch next stands.")
    }

    @objc private func setCap(_ sender: NSPopUpButton) {
        Settings.capGB = Self.capChoices[sender.indexOfSelectedItem].1
        onRestartNeeded?()
        note("Memory ceiling changes when the watch next stands.")
    }

    @objc private func setScale(_ sender: NSPopUpButton) {
        Settings.scale = Self.scaleChoices[sender.indexOfSelectedItem].1
        onRestartNeeded?()
        note("Capture size changes when the watch next stands.")
    }

    @objc private func setFPS(_ sender: NSPopUpButton) {
        Settings.fps = Self.fpsChoices[sender.indexOfSelectedItem].1
        onRestartNeeded?()
        note("Frame rate changes when the watch next stands.")
    }

    @objc private func setCodec(_ sender: NSPopUpButton) {
        Settings.codec = sender.indexOfSelectedItem == 1 ? "h264" : "hevc"
        onRestartNeeded?()
        note("Codec changes when the watch next stands. Quit and start it again.")
    }

    // MARK: - Window

    func show() {
        let window = self.window ?? build()
        self.window = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) { window = nil }

    func sample(into directory: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                let window = self.build()
                defer { continuation.resume() }
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: directory.appendingPathComponent("preferences.png"))
            }
        }
    }
}
