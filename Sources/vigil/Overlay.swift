import AppKit

/// A borderless window that floats above a fullscreen game.
///
/// Not decoration — an instrument. Without visible feedback there is no way to
/// tell a hotkey that did not fire from one that fired into silence.
///
/// The two things that matter structurally: `.screenSaver` level plus
/// `.fullScreenAuxiliary` so it draws over a fullscreen space, and
/// `orderFrontRegardless()` rather than `makeKeyAndOrderFront` so it never
/// steals focus from EVE. Taking focus mid-fight would be worse than no overlay.
///
/// Dressed as Ministry stationery: ink ground, a hairline rule, Geist Mono
/// micro-caps, and the office seal struck at the left of the row. The seal is
/// the canonical plate, not a re-render — see `Resources/STRIKE.md`.
final class Overlay: @unchecked Sendable {   // only ever touched on main

    // The house ink, from docs/stationery.md.
    enum Ink {
        static let ground = NSColor(srgbRed: 0.071, green: 0.063, blue: 0.055, alpha: 0.94) // --ink
        static let line   = NSColor(srgbRed: 0.227, green: 0.208, blue: 0.188, alpha: 1)    // --line
        static let bone   = NSColor(srgbRed: 0.910, green: 0.886, blue: 0.851, alpha: 1)    // --bone
        static let fog    = NSColor(srgbRed: 0.659, green: 0.620, blue: 0.565, alpha: 1)    // --fog
        static let dim    = NSColor(srgbRed: 0.541, green: 0.502, blue: 0.455, alpha: 1)    // --dim
        static let rust   = NSColor(srgbRed: 0.757, green: 0.373, blue: 0.235, alpha: 1)    // --rust
        static let bright = NSColor(srgbRed: 0.878, green: 0.482, blue: 0.322, alpha: 1)    // --bright
        static let blood  = NSColor(srgbRed: 0.753, green: 0.271, blue: 0.263, alpha: 1)    // --blood
        static let sage   = NSColor(srgbRed: 0.490, green: 0.608, blue: 0.463, alpha: 1)    // --sage
    }

    private static let size = NSSize(width: 408, height: 88)
    private static let sealSize: CGFloat = 64

    private var window: NSWindow?
    private var label: NSTextField?
    private var detail: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    /// Geist Mono if the estate's face is installed, the system monospace if not.
    private static func mono(_ points: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        NSFont(name: "GeistMono-Medium", size: points)
            ?? NSFont.monospacedSystemFont(ofSize: points, weight: weight)
    }

    /// Micro-caps: uppercase, letter-spaced. The stationery calls this the most
    /// recognisable element of the house style, so it is not negotiable.
    private static func microCaps(_ text: String, size points: CGFloat,
                                  tracking: CGFloat, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: mono(points),
            .kern: points * tracking,
            .foregroundColor: color
        ])
    }

    private func build() -> NSWindow {
        let size = Self.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = Ink.ground.cgColor
        content.layer?.cornerRadius = 4
        content.layer?.borderWidth = 1
        content.layer?.borderColor = Ink.line.cgColor

        // The seal, struck at the left of the row, rotated as the front page
        // wears it.
        if let seal = MinistryMark.seal {
            let view = NSImageView(frame: NSRect(x: 16, y: (size.height - Self.sealSize) / 2,
                                                 width: Self.sealSize, height: Self.sealSize))
            view.image = seal
            view.imageScaling = .scaleProportionallyUpOrDown
            view.frameCenterRotation = -5
            content.addSubview(view)
        }

        let textLeft: CGFloat = 16 + Self.sealSize + 18
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: textLeft, y: 44, width: size.width - textLeft - 16, height: 22)
        content.addSubview(label)
        self.label = label

        let detail = NSTextField(labelWithString: "")
        detail.frame = NSRect(x: textLeft, y: 24, width: size.width - textLeft - 16, height: 16)
        content.addSubview(detail)
        self.detail = detail

        window.contentView = content
        return window
    }

    /// Bottom centre of the screen holding the mouse — clear of EVE's HUD
    /// corners, where a game's own notices live.
    private func reposition(_ window: NSWindow) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        window.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2,
                                      y: frame.minY + 110))
    }

    /// Put the window on screen before ScreenCaptureKit is asked what is
    /// shareable. An application with no on-screen window does not appear in
    /// SCShareableContent, and an app we cannot name is an app we cannot
    /// exclude from the capture.
    func prepare() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                self.render("Vigil", stamp: "Standing", tint: Ink.fog)
                continuation.resume()
            }
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private func render(_ text: String, stamp stampText: String, tint: NSColor) {
        let window = self.window ?? build()
        self.window = window
        label?.attributedStringValue = Self.microCaps(text, size: 15, tracking: 0.18,
                                                      color: Ink.bone)
        detail?.attributedStringValue = Self.microCaps(stampText, size: 9.5,
                                                      tracking: 0.16, color: tint)
        reposition(window)
        window.alphaValue = 1
        window.orderFrontRegardless()   // never makeKeyAndOrderFront
    }

    /// Render each state to a PNG. A dev affordance: iterating on the
    /// stationery should not require a capture run and a lucky frame grab.
    func sample(into directory: URL) async {
        let states: [(String, String, String, NSColor)] = [
            ("1-observing", "Observing",  "Buffer live",  Ink.sage),
            ("2-witnessing", "Witnessing", "from −300 s", Ink.bright),
            ("3-filing",    "Filing",     "in hand",      Ink.fog),
            ("4-filed",     "Filed",      "306 s",        Ink.sage),
            ("5-empty",     "Observing",  "Nothing held", Ink.fog),
            ("6-failed",    "Not filed",  "Failed",       Ink.blood)
        ]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // NSWindow is main-thread-only, and start() runs inside a Task.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                for (name, text, stampText, tint) in states {
                    self.render(text, stamp: stampText, tint: tint)
                    guard let view = self.window?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                    try? png.write(to: directory.appendingPathComponent("\(name).png"))
                }
                // The menu-bar glyph too, blown up so it can be checked.
                let glyph = MinistryMark.glyph(height: 120)
                if let tiff = glyph.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent("glyph.png"))
                }
                self.window?.orderOut(nil)
                continuation.resume()
            }
        }
    }

    func flash(_ text: String, stamp stampText: String,
               tint: NSColor = Ink.sage, seconds: TimeInterval = 1.8) {
        DispatchQueue.main.async {
            self.hideWorkItem?.cancel()
            self.render(text, stamp: stampText, tint: tint)

            let hide = DispatchWorkItem { [weak self] in
                guard let window = self?.window else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.45
                    window.animator().alphaValue = 0
                } completionHandler: {
                    window.orderOut(nil)
                }
            }
            self.hideWorkItem = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: hide)
        }
    }
}
