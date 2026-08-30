import Foundation
import ScreenCaptureKit
import CoreMedia

/// ScreenCaptureKit set up the way v1 will want it: whole display, no cursor,
/// no SCK audio (the tap owns audio), 4:2:0 rather than BGRA.
final class VideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.observance.witness.video", qos: .userInitiated)

    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    private(set) var displayDescription = ""
    private(set) var excludedSelf = false

    var onFrame: ((CMSampleBuffer) -> Void)?
    var onSkippedIncomplete: (() -> Void)?
    var onStop: ((Error) -> Void)?

    func start(config: Config) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SpikeError("no display available to capture")
        }

        // Exclude ourselves, or every saved clip carries our own overlay into
        // the edit. Excluding by application rather than by window covers the
        // overlay even though it is built lazily.
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let ours = content.applications.filter { $0.processID == ourPID }
        let filter: SCContentFilter
        if ours.isEmpty {
            Log.warn("could not find this app in the shareable content list — "
                     + "the overlay will appear in saved clips")
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            filter = SCContentFilter(display: display,
                                     excludingApplications: ours,
                                     exceptingWindows: [])
            excludedSelf = true
        }

        // SCDisplay.width/height are POINTS. On a Retina panel that is half the
        // real thing — asking for display.width here quietly captures quarter
        // resolution. pointPixelScale is the backing scale factor.
        let scaleFactor = Double(filter.pointPixelScale)
        let nativeW = Int(Double(display.width) * scaleFactor)
        let nativeH = Int(Double(display.height) * scaleFactor)
        pixelWidth  = (Int(Double(nativeW) * config.scale) / 2) * 2
        pixelHeight = (Int(Double(nativeH) * config.scale) / 2) * 2
        displayDescription = "\(display.width)×\(display.height) pt @\(String(format: "%g", scaleFactor))x = \(nativeW)×\(nativeH) px"

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: config.fps)
        // 4:2:0 full range, not BGRA: half the bandwidth off the capture path
        // and it is what the encoder wants anyway.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false      // the Core Audio tap owns audio
        configuration.queueDepth = 8
        configuration.captureResolution = .best

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

        // SCK only delivers on change. Docked with the station spin off, EVE
        // emits .idle frames with no image attached — writing them corrupts the
        // timeline. This check is why v1 measures its ring in PTS, not frames.
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
