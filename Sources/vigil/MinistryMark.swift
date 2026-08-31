import AppKit

/// The estate's two marks.
///
/// The **seal** — rings, arc text, glyph — is a struck plate loaded from the
/// bundle. It cannot be re-rendered here: the ring text is Zilla Slab on a
/// textPath, and under a wider fallback SVG silently drops the characters that
/// overrun the path. See `Resources/STRIKE.md`.
///
/// The **glyph** — the triangle and eye at the seal's centre — is drawn, not
/// loaded, because it has to stay crisp at 18pt in the menu bar where a scaled
/// seal would be mud. This is the same division the stationery makes: the seal
/// goes on the document, the glyph goes on the rail.
enum MinistryMark {

    static let seal: NSImage? = {
        guard let url = Bundle.main.url(forResource: "seal", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }()

    /// Triangle, eye, pupil — the paths from the seal's centre group, flipped
    /// into AppKit's y-up space. Even-odd winding punches the eye out of the
    /// triangle and drops the pupil back in, so it works as a template image
    /// where only alpha survives.
    /// Pass a colour to get a tinted, non-template image. A template image
    /// takes the menu bar's own colour and cannot be made red, and red is what
    /// a recording indicator has to be.
    static func glyph(height: CGFloat, color: NSColor? = nil) -> NSImage {
        let artWidth: CGFloat = 184, artHeight: CGFloat = 150   // x −92…92, y −50…100
        let scale = height / artHeight
        let size = NSSize(width: (artWidth * scale).rounded(), height: height.rounded())

        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: 0, y: -25)   // art centre sits above the box centre

            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: 100))
            path.line(to: NSPoint(x: 92, y: -50))
            path.line(to: NSPoint(x: -92, y: -50))
            path.close()

            path.move(to: NSPoint(x: -56, y: -8))
            path.curve(to: NSPoint(x: 56, y: -8),
                       controlPoint1: NSPoint(x: -18.7, y: 34.7),
                       controlPoint2: NSPoint(x: 18.7, y: 34.7))
            path.curve(to: NSPoint(x: -56, y: -8),
                       controlPoint1: NSPoint(x: 18.7, y: -65.6),
                       controlPoint2: NSPoint(x: -18.7, y: -65.6))
            path.close()

            path.appendOval(in: NSRect(x: -22, y: -30, width: 44, height: 44))

            path.windingRule = .evenOdd
            (color ?? .black).setFill()
            path.fill()
            return true
        }
        image.isTemplate = (color == nil)
        return image
    }
}
