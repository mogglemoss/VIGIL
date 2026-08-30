import AppKit

/// A borderless window that floats above a fullscreen game.
///
/// Not a feature — an instrument. Without visible feedback there is no way to
/// tell a hotkey that did not fire from one that fired into silence, which
/// makes the whole hotkey question untestable.
///
/// The two things that matter here: `.screenSaver` level plus
/// `.fullScreenAuxiliary` so it draws over a fullscreen space, and
/// `orderFrontRegardless()` rather than `makeKeyAndOrderFront` so it never
/// steals focus from EVE. Taking focus mid-fight would be worse than no overlay.
final class Overlay {
    private var window: NSWindow?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    // Ministry stationery.
    private static let ink   = NSColor(red: 0.071, green: 0.063, blue: 0.055, alpha: 0.92)  // #12100e
    private static let bone  = NSColor(red: 0.910, green: 0.886, blue: 0.851, alpha: 1.0)   // #e8e2d9
    private static let rust  = NSColor(red: 0.757, green: 0.373, blue: 0.235, alpha: 1.0)   // #c15f3c

    private func build() -> NSWindow {
        let size = NSSize(width: 320, height: 54)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
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
        content.layer?.backgroundColor = Self.ink.cgColor
        content.layer?.cornerRadius = 4
        content.layer?.borderWidth = 1
        content.layer?.borderColor = Self.rust.withAlphaComponent(0.55).cgColor

        let text = NSTextField(labelWithString: "")
        text.font = NSFont(name: "GeistMono-Medium", size: 15)
            ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        text.textColor = Self.bone
        text.alignment = .center
        text.frame = NSRect(x: 0, y: 17, width: size.width, height: 20)
        content.addSubview(text)

        window.contentView = content
        self.label = text
        return window
    }

    /// Bottom centre of the screen holding the mouse — where a game's own
    /// notifications live, and clear of EVE's HUD corners.
    private func reposition(_ window: NSWindow) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                      y: frame.minY + 110))
    }

    func flash(_ message: String, seconds: TimeInterval = 1.6) {
        DispatchQueue.main.async {
            let window = self.window ?? self.build()
            self.window = window
            self.label?.stringValue = message
            self.reposition(window)

            self.hideWorkItem?.cancel()
            window.alphaValue = 1
            window.orderFrontRegardless()   // never makeKeyAndOrderFront

            let hide = DispatchWorkItem { [weak window] in
                guard let window else { return }
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
