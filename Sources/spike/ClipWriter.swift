import Foundation
import AVFoundation
import CoreMedia

/// Writes one clip: the buffered past, then live frames until stopped.
///
/// Video is **passthrough** — `outputSettings: nil` with a source format hint,
/// so the already-encoded samples are muxed as they are. Nothing is re-encoded,
/// which is why a five-minute clip lands in about a second.
///
/// Everything runs on one serial queue so the snapshot is fully written before
/// any live frame can jump ahead of it.
final class ClipWriter: @unchecked Sendable {   // serialised by `queue`
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "app.observance.spike.clip", qos: .utility)
    private var sessionStarted = false
    private var finished = false

    let url: URL
    let startedFrom: Double        // seconds of buffered past this clip opened with
    var hasAudio: Bool { audioInput != nil }
    private(set) var framesWritten = 0
    private(set) var framesRejected = 0
    private(set) var audioAppended = 0
    private(set) var lastVideoPTS = CMTime.zero
    private(set) var lastAudioPTS = CMTime.zero

    private let audioASBD: AudioStreamBasicDescription
    private let audioFormat: CMFormatDescription?
    private var expectedAudioPTS = CMTime.invalid
    private var sessionStart = CMTime.invalid
    private(set) var silenceInserted: Double = 0

    init(url: URL, snapshot: ReplayBuffer.Snapshot,
         audioASBD: AudioStreamBasicDescription,
         audioFormat: CMFormatDescription?) throws {
        self.audioASBD = audioASBD
        self.audioFormat = audioFormat
        self.url = url
        self.startedFrom = snapshot.seconds
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // nil settings + format hint = mux, do not encode.
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                        sourceFormatHint: snapshot.format)
        videoInput.expectsMediaDataInRealTime = true

        // No tap attached (EVE quit and has not come back) means a video-only
        // clip. Better than refusing to save the fight.
        if audioFormat != nil && audioASBD.mSampleRate > 0 {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioASBD.mSampleRate,
                AVNumberOfChannelsKey: Int(audioASBD.mChannelsPerFrame),
                AVEncoderBitRateKey: 256_000
            ])
            input.expectsMediaDataInRealTime = true
            audioInput = input
        } else {
            audioInput = nil
        }

        guard writer.canAdd(videoInput) else { throw SpikeError("writer rejected the video input") }
        writer.add(videoInput)
        if let audioInput {
            guard writer.canAdd(audioInput) else { throw SpikeError("writer rejected the audio input") }
            writer.add(audioInput)
        }
        guard writer.startWriting() else {
            throw writer.error ?? SpikeError("startWriting() returned false")
        }

        // Drain the buffered past first. Live frames enqueued behind it on the
        // same serial queue cannot overtake it.
        queue.async { [weak self] in
            guard let self else { return }
            for frame in snapshot.video { self.write(frame.sample, to: self.videoInput) }
            if self.audioInput != nil {
                for sample in snapshot.audio { self.writeAudio(sample) }
            }
        }
    }

    private func write(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) {
        guard !finished, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if !sessionStarted {
            guard input === videoInput else { return }   // anchor on video
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
            sessionStarted = true
        }
        // Passthrough muxing is fast, but not instant. Spin briefly rather than
        // dropping — a dropped frame in the middle of a saved clip is a glitch
        // the viewer sees.
        var waited = 0
        while !input.isReadyForMoreMediaData && waited < 200 {
            usleep(1000); waited += 1
        }
        guard input.isReadyForMoreMediaData else { framesRejected += 1; return }
        if input.append(sample) {
            if input === videoInput { framesWritten += 1; lastVideoPTS = pts }
            else { audioAppended += 1; lastAudioPTS = pts }
        } else {
            framesRejected += 1
        }
    }

    /// A Core Audio tap is NOT gapless: when no tapped process is producing
    /// output it delivers nothing at all. AVAssetWriter concatenates whatever
    /// it is handed, so an unfilled gap does not leave a hole — it drags every
    /// later sample earlier, and audio slides ahead of video for the rest of
    /// the clip. Every gap has to be paid for in silence.
    private func writeAudio(_ sample: CMSampleBuffer) {
        guard sessionStarted, let audioInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let anchor = expectedAudioPTS.isValid ? expectedAudioPTS : sessionStart
        if anchor.isValid {
            let gap = CMTimeSubtract(pts, anchor)
            if CMTimeGetSeconds(gap) > 0.002, let silence = makeSilence(covering: gap, at: anchor) {
                write(silence, to: audioInput)
                silenceInserted += CMTimeGetSeconds(gap)
            }
        }
        write(sample, to: audioInput)
        expectedAudioPTS = CMTimeAdd(pts, CMSampleBufferGetDuration(sample))
    }

    private func makeSilence(covering duration: CMTime, at pts: CMTime) -> CMSampleBuffer? {
        guard let audioFormat, audioASBD.mSampleRate > 0 else { return nil }
        let frames = Int(CMTimeGetSeconds(duration) * audioASBD.mSampleRate)
        guard frames > 0, frames < Int(audioASBD.mSampleRate) * 60 else { return nil }
        let frameBytes = Int(audioASBD.mBytesPerFrame)
        let total = frames * frameBytes

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil, blockLength: total,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0, dataLength: total,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block,
                                         offsetIntoDestination: 0,
                                         dataLength: total) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(audioASBD.mSampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = frameBytes
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: block,
                                        formatDescription: audioFormat,
                                        sampleCount: frames,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }

    /// Live frames, after the snapshot. Ordering is the queue's job.
    func append(video sample: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            self.write(sample, to: self.videoInput)
        }
    }

    func append(audio sample: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            self.writeAudio(sample)
        }
    }

    func finish() async -> (url: URL, seconds: Double, bytes: Int64) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { self.finished = true; continuation.resume() }
        }
        if framesRejected > 0 || silenceInserted > 0.25 {
            Log.warn(String(format: "clip: %d frames rejected, %.2f s of silence filled in",
                            framesRejected, silenceInserted))
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        var seconds = 0.0
        if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let range = try? await track.load(.timeRange) {
            seconds = CMTimeGetSeconds(range.duration)
        }
        return (url, seconds, bytes)
    }
}
