import Foundation
import ScreenCaptureKit
import CoreMedia

enum CaptureTarget {
    /// Only this application's window. Nothing else on the machine is seen.
    case app(names: [String])
    /// The whole display, everything on it. Available, never the default.
    case display
}

/// ScreenCaptureKit, aimed at the game rather than at the screen.
///
/// The default target is EVE's own window. Capturing the display was wrong in a
/// way that only shows up in the saved clip: the ring held five minutes of
/// whatever was in front of you, and a clip caught the switch into the game.
/// Filtering to the window means the buffer cannot contain anything but EVE,
/// which is a privacy property and not merely a tidier frame.
final class VideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    struct TargetMissing: LocalizedError {
        let names: [String]
        var errorDescription: String? {
            "no window found for \(names.joined(separator: ", "))"
        }
    }

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.observance.vigil.video", qos: .userInitiated)

    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    private(set) var displayDescription = ""
    private(set) var excludedSelf = false
    /// Kept so the title can be re-read cheaply later: a pilot switches
    /// character without the window changing, and the name in the title
    /// changes with them.
    private(set) var targetWindowID: CGWindowID?

    /// The window's title as it reads right now, not as it read at attach.
    ///
    /// `.optionAll` and not `CGWindowListCreateDescriptionFromArray`: the latter
    /// returns nothing at all for a fullscreen game, because it only sees the
    /// current Space. The same trap as `onScreenWindowsOnly`, in a different
    /// API, an hour apart.
    var currentTitle: String? {
        guard let targetWindowID else { return nil }
        guard let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in all {
            guard let number = window[kCGWindowNumber as String] as? CGWindowID,
                  number == targetWindowID else { continue }
            guard let name = window[kCGWindowName as String] as? String,
                  !name.isEmpty else { return nil }
            return name
        }
        return nil
    }

    /// EVE titles its window "EVE - Cormorant Fell". Anything after the last
    /// separator is the pilot; a client sitting at character select has no
    /// separator and no pilot, which is correct rather than a failure.
    var pilotName: String? {
        guard let title = currentTitle else { return nil }
        for separator in [" - ", " — ", " – "] {
            if let range = title.range(of: separator, options: .backwards) {
                let name = String(title[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    var onFrame: ((CMSampleBuffer) -> Void)?
    var onSkippedIncomplete: (() -> Void)?
    var onStop: ((Error) -> Void)?

    // MARK: - Resolving the target

    /// A window is EVE's if its owner matches by bundle identifier (exactly or
    /// as a prefix) or by application name. Unlike Core Audio — which reports
    /// no bundle for the client at all — ScreenCaptureKit names it properly as
    /// com.ccpgames.eveonline.
    private static func matches(_ token: String, _ app: SCRunningApplication) -> Bool {
        let bundle = app.bundleIdentifier
        if bundle == token || bundle.hasPrefix(token + ".") { return true }
        if app.applicationName.range(of: token, options: .caseInsensitive) != nil { return true }
        // "EVE.app" is the audio-side handle; accept it here too so one setting
        // can drive both.
        if token.hasSuffix(".app"),
           app.applicationName.range(of: String(token.dropLast(4)),
                                     options: .caseInsensitive) != nil { return true }
        return false
    }

    private func resolve(_ target: CaptureTarget) async throws -> (SCContentFilter, String) {
        // onScreenWindowsOnly: false — a fullscreen game is on its own Space and
        // the on-screen filter hides it entirely. This is why aiming at a window
        // appeared not to work at all until it was looked at directly.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)

        switch target {
        case .display:
            targetWindowID = nil
            guard let display = content.displays.first else {
                throw SpikeError("no display available to capture")
            }
            let ourPID = ProcessInfo.processInfo.processIdentifier
            let ours = content.applications.filter { $0.processID == ourPID }
            let filter = ours.isEmpty
                ? SCContentFilter(display: display, excludingWindows: [])
                : SCContentFilter(display: display, excludingApplications: ours,
                                  exceptingWindows: [])
            excludedSelf = !ours.isEmpty
            return (filter, "whole display")

        case .app(let names):
            // The largest real window the app owns. Games spawn tooltip and
            // helper windows; the one being played is the big one.
            let candidates = content.windows.filter { window in
                guard let owner = window.owningApplication else { return false }
                guard names.contains(where: { Self.matches($0, owner) }) else { return false }
                return window.frame.width > 200 && window.frame.height > 200
            }
            guard let window = candidates.max(by: {
                ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
            }) else {
                throw TargetMissing(names: names)
            }
            excludedSelf = true   // nothing but this window is in the filter
            targetWindowID = window.windowID
            let owner = window.owningApplication?.applicationName ?? "?"
            let title = window.title.map { " · \($0)" } ?? ""
            return (SCContentFilter(desktopIndependentWindow: window), "\(owner)\(title)")
        }
    }

    // MARK: - Lifecycle

    func start(config: Config) async throws {
        let (filter, described) = try await resolve(config.target)

        // contentRect is in points; pointPixelScale is the backing factor. Using
        // the point size directly captures quarter resolution and looks fine.
        let scaleFactor = Double(filter.pointPixelScale)
        let nativeW = Int(filter.contentRect.width * scaleFactor)
        let nativeH = Int(filter.contentRect.height * scaleFactor)
        pixelWidth = max(2, (Int(Double(nativeW) * config.scale) / 2) * 2)
        pixelHeight = max(2, (Int(Double(nativeH) * config.scale) / 2) * 2)
        displayDescription = "\(described) — \(nativeW)×\(nativeH) px"

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: config.fps)
        // 4:2:0 full range, not BGRA: half the bandwidth off the capture path,
        // and it is what the encoder wants anyway.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false      // the Core Audio tap owns audio
        configuration.queueDepth = 8
        configuration.captureResolution = .best
        configuration.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        // ScreenCaptureKit only delivers on change. Docked with the station spin
        // off, EVE emits .idle frames with no image attached — writing them
        // corrupts the timeline. This is why the ring is measured in PTS.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw),
              status == .complete else {
            onSkippedIncomplete?()
            return
        }
        onFrame?(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
