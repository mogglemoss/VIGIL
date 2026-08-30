import AppKit

/// The office's own paperwork about itself.
///
/// A real window rather than the overlay, because it is asked for deliberately
/// and read at leisure. It does take focus — but you only ever open it from the
/// menu bar, which already means you are not flying.
final class About: NSObject, NSWindowDelegate, @unchecked Sendable {   // main only

    private var window: NSWindow?
    private static let size = NSSize(width: 460, height: 612)

    private static func mono(_ points: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        NSFont(name: "GeistMono-Medium", size: points)
            ?? NSFont.monospacedSystemFont(ofSize: points, weight: weight)
    }

    private static func caps(_ text: String, size points: CGFloat, tracking: CGFloat,
                             color: NSColor, alignment: NSTextAlignment = .center) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        return NSAttributedString(string: text.uppercased(), attributes: [
            .font: mono(points), .kern: points * tracking,
            .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }

    private static func body(_ text: String, size points: CGFloat, color: NSColor,
                             alignment: NSTextAlignment = .center) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = 4
        return NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "Geist-Regular", size: points)
                ?? NSFont.systemFont(ofSize: points),
            .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }

    private static func label(_ attributed: NSAttributedString, y: CGFloat,
                              height: CGFloat, inset: CGFloat = 40) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: attributed)
        field.frame = NSRect(x: inset, y: y, width: size.width - inset * 2, height: height)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }

    private static func rule(y: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 56, y: y, width: size.width - 112, height: 1))
        view.wantsLayer = true
        view.layer?.backgroundColor = Overlay.Ink.line.cgColor
        return view
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) · build \(build)"
    }

    func build() -> NSWindow {
        let size = Self.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "VIGIL"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(srgbRed: 0.071, green: 0.063, blue: 0.055, alpha: 1)
        window.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        // The ground belongs on the view, not just the window: the window's
        // colour is not in what cacheDisplay captures, and a document with no
        // paper under it is not a document.
        content.layer?.backgroundColor = Overlay.Ink.ground.withAlphaComponent(1).cgColor

        // The seal, as the front page wears it.
        if let seal = MinistryMark.seal {
            let view = NSImageView(frame: NSRect(x: (size.width - 132) / 2, y: 452,
                                                 width: 132, height: 132))
            view.image = seal
            view.imageScaling = .scaleProportionallyUpOrDown
            view.frameCenterRotation = -5
            content.addSubview(view)
        }

        content.addSubview(Self.label(Self.caps("Vigil", size: 25, tracking: 0.22,
                                                color: Overlay.Ink.rust),
                                      y: 408, height: 32))
        content.addSubview(Self.label(Self.caps("The Ministry of Pantoscopic Observance",
                                                size: 8.5, tracking: 0.22, color: Overlay.Ink.dim),
                                      y: 388, height: 14))
        content.addSubview(Self.label(Self.caps("Office of the Standing Watch · Retrospective Attestation Instrument",
                                                size: 8.5, tracking: 0.16, color: Overlay.Ink.dim),
                                      y: 352, height: 28, inset: 52))

        content.addSubview(Self.rule(y: 338))

        content.addSubview(Self.label(
            Self.body("A standing watch over your client. The preceding minutes are held in "
                      + "memory and overwritten unread; nothing reaches the disk until you "
                      + "strike the record, at which point the watch continues until you "
                      + "close it.",
                      size: 12.5, color: Overlay.Ink.fog),
            y: 244, height: 78, inset: 52))

        content.addSubview(Self.rule(y: 228))

        // The form block, in the house's stamped register.
        let form = """
        FORM OSW-01 (RETROSPECTIVE ATTESTATION)

        THE MINISTRY RETAINS NO RECORD IT HAS NOT
        BEEN INSTRUCTED TO RETAIN. THE PRECEDING
        MINUTES ARE HELD IN CONFIDENCE, AND ARE
        OVERWRITTEN UNREAD.

        EVERYTHING ABOVE OBSERVES; NOTHING ABOVE
        JUDGES. THE MINISTRY IS MERELY NOTING.
        """
        content.addSubview(Self.label(Self.caps(form, size: 8.5, tracking: 0.10,
                                                color: Overlay.Ink.sage, alignment: .left),
                                      y: 104, height: 108, inset: 60))

        content.addSubview(Self.rule(y: 86))

        content.addSubview(Self.label(Self.body("Public record is public good", size: 12,
                                                color: Overlay.Ink.bone),
                                      y: 54, height: 20))
        content.addSubview(Self.label(Self.caps("Rev. \(version)", size: 8,
                                                tracking: 0.18, color: Overlay.Ink.dim),
                                      y: 34, height: 14))
        content.addSubview(Self.label(
            Self.caps("Not affiliated with Fenris Creations", size: 7.5, tracking: 0.16,
                      color: Overlay.Ink.line.blended(withFraction: 0.6, of: Overlay.Ink.dim)
                        ?? Overlay.Ink.dim),
            y: 16, height: 12))

        window.contentView = content
        return window
    }

    func show() {
        let window = self.window ?? build()
        self.window = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// Rendered to PNG by `--overlay-sample`, so the stationery can be checked
    /// without opening it by hand.
    func sample(into directory: URL) async {
        // NSWindow is main-thread-only, and start() runs inside a Task.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                let window = self.build()
                defer { continuation.resume() }
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: directory.appendingPathComponent("about.png"))
            }
        }
    }
}
