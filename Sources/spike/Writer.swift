import Foundation
import AVFoundation
import CoreMedia

/// AVAssetWriter, on purpose.
///
/// v1 needs a raw VTCompressionSession so encoded frames can go into the ring
/// buffer instead of a file. But AVAssetWriter drives the same hardware HEVC
/// encoder, so the performance number this spike produces still transfers —
/// and it saves ~300 lines we would throw away.
final class Writer {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private var sessionStarted = false
    let url: URL

    var isFailed: Bool { writer.status == .failed }
    var failure: Error? { writer.error }

    init(url: URL, width: Int, height: Int, fps: Int32,
         codec: AVVideoCodecType, bitrate: Int,
         audioASBD: AudioStreamBasicDescription) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(fps),
            // 1-second GOP. Irrelevant for this file, load-bearing for v1:
            // saving a clip without re-encoding means starting on an IDR.
            AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            // No B-frames. Reordering costs latency and complicates ring trims.
            AVVideoAllowFrameReorderingKey: false
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ])
        videoInput.expectsMediaDataInRealTime = true

        let asbd = audioASBD
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
            AVEncoderBitRateKey: 256_000
        ])
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else { throw Err("writer rejected the video input") }
        writer.add(videoInput)
        guard writer.canAdd(audioInput) else { throw Err("writer rejected the audio input") }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw writer.error ?? Err("startWriting() returned false")
        }
    }

    struct Err: LocalizedError { let m: String; init(_ m: String) { self.m = m }
        var errorDescription: String? { m } }

    /// The session clock is anchored on the first video frame. Audio that
    /// arrives before it is discarded rather than clamped — clamping is how you
    /// get a clip that starts with a burst of stale sound.
    @discardableResult
    func startSessionIfNeeded(at time: CMTime) -> Bool {
        guard !sessionStarted else { return true }
        guard time.isValid && time.isNumeric else { return false }
        writer.startSession(atSourceTime: time)
        sessionStarted = true
        return true
    }

    var hasStarted: Bool { sessionStarted }

    enum Outcome { case wrote, notReady, notStarted, failed }

    func appendVideo(_ sample: CMSampleBuffer) -> Outcome {
        guard writer.status == .writing else { return .failed }
        guard videoInput.isReadyForMoreMediaData else { return .notReady }
        return videoInput.append(sample) ? .wrote : .failed
    }

    func appendAudio(_ sample: CMSampleBuffer) -> Outcome {
        guard writer.status == .writing else { return .failed }
        guard sessionStarted else { return .notStarted }
        guard audioInput.isReadyForMoreMediaData else { return .notReady }
        return audioInput.append(sample) ? .wrote : .failed
    }

    var bytesOnDisk: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    func finish() async {
        guard writer.status == .writing else { return }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await writer.finishWriting()
    }
}
