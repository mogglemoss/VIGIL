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
/// micro-caps, and the rotated stamp from the registry panel —
/// `rotate(4deg)`, 1.5px border in the state's ink.
final class Overlay: @unchecked Sendable {   // only ever touched on main

    // The house ink, from docs/stationery.md.
    enum Ink {
        static let ground = NSColor(srgbRed: 0.071, green: 0.063, blue: 0.055, alpha: 0.94) // --ink
        static let line   = NSColor(srgbRed: 0.227, green: 0.208, blue: 0.188, alpha: 1)    // --line
        static let bone   = NSColor(srgbRed: 0.910, green: 0.886, blue: 0.851, alpha: 1)    // --bone
        static let fog    = NSColor(srgbRed: 0.659, green: 0.620, blue: 0.565, alpha: 1)    // --fog
        static let rust   = NSColor(srgbRed: 0.757, green: 0.373, blue: 0.235, alpha: 1)    // --rust
        static let bright = NSColor(srgbRed: 0.878, green: 0.482, blue: 0.322, alpha: 1)    // --bright
        static let blood  = NSColor(srgbRed: 0.753, green: 0.271, blue: 0.263, alpha: 1)    // --blood
        static let sage   = NSColor(srgbRed: 0.490, green: 0.608, blue: 0.463, alpha: 1)    // --sage
    }

    private static let size = NSSize(width: 372, height: 56)

    private var window: NSWindow?
    private var label: NSTextField?
    private var stamp: NSTextField?
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

        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 18, y: 19, width: size.width - 150, height: 20)
        content.addSubview(label)
        self.label = label

        // The registry stamp: rotate(4deg), 1.5px border in currentColor.
        let stamp = NSTextField(labelWithString: "")
        stamp.wantsLayer = true
        stamp.alignment = .center
        stamp.layer?.borderWidth = 1.5
        stamp.layer?.cornerRadius = 3
        stamp.frameCenterRotation = 4
        stamp.alphaValue = 0.9
        content.addSubview(stamp)
        self.stamp = stamp

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
                self.render("Observance", stamp: "Starting", tint: Ink.fog)
                continuation.resume()
            }
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private func render(_ text: String, stamp stampText: String, tint: NSColor) {
        let window = self.window ?? build()
        self.window = window
        label?.attributedStringValue = Self.microCaps(text, size: 14, tracking: 0.18,
                                                      color: Ink.bone)
        if let stamp {
            stamp.attributedStringValue = Self.microCaps(stampText, size: 9,
                                                         tracking: 0.12, color: tint)
            stamp.sizeToFit()
            let width = stamp.frame.width + 12
            stamp.frame = NSRect(x: Self.size.width - width - 18,
                                 y: 21, width: width, height: 17)
            stamp.frameCenterRotation = 4
            stamp.layer?.borderColor = tint.cgColor
        }
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
