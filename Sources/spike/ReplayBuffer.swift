import Foundation
import CoreMedia

/// The ring. Encoded video in segments, PCM audio in a flat window.
///
/// Two things this gets right that a naive implementation does not:
///
/// **Segments, not one buffer.** Display sleep, a resolution change, EVE going
/// fullscreen — each restarts the encoder and produces a new format
/// description. Frames either side of that boundary cannot be concatenated
/// without re-encoding, so the ring is a list of segments and a clip is cut
/// from one of them.
///
/// **Measured in PTS, not frames.** ScreenCaptureKit only delivers on change.
/// Docked with the station spin off, EVE emits almost nothing, and a ring that
/// counted frames would quietly hold forty minutes instead of five.
final class ReplayBuffer {

    struct Frame {
        let sample: CMSampleBuffer
        let pts: CMTime
        let isKey: Bool
        let bytes: Int
    }

    final class Segment {
        let format: CMFormatDescription
        var frames: [Frame] = []
        var bytes = 0
        init(format: CMFormatDescription) { self.format = format }
        var duration: Double {
            guard let first = frames.first, let last = frames.last else { return 0 }
            return CMTimeGetSeconds(CMTimeSubtract(last.pts, first.pts))
        }
    }

    /// A consistent view of the ring, taken under the lock and muxed outside it.
    struct Snapshot {
        let format: CMFormatDescription
        let video: [Frame]
        let audio: [CMSampleBuffer]
        let cutoff: CMTime          // newest video PTS at snapshot time
        let seconds: Double
        let coversFullWindow: Bool
    }

    private let lock = NSLock()
    private var segments: [Segment] = []
    private var audio: [(sample: CMSampleBuffer, pts: CMTime, bytes: Int)] = []

    private(set) var window: Double  // seconds to retain
    let byteCap: Int                // hard ceiling, whatever the window says

    private(set) var videoBytes = 0
    private(set) var audioBytes = 0
    private(set) var segmentBreaks = 0
    private(set) var cappedEvictions = 0

    init(window: Double, byteCap: Int) {
        self.window = window
        self.byteCap = byteCap
    }

    var bytes: Int { videoBytes + audioBytes }

    /// Changing the window live is safe: shrinking takes effect on the next
    /// append, growing simply fills over time.
    func setWindow(_ seconds: Double) {
        lock.lock(); window = seconds; lock.unlock()
    }

    var heldSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return segments.last?.duration ?? 0
    }

    // MARK: - Append

    func append(video sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid && pts.isNumeric,
              let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let frame = Frame(sample: sample, pts: pts,
                          isKey: Encoder.isKeyframe(sample),
                          bytes: CMSampleBufferGetTotalSampleSize(sample))

        lock.lock(); defer { lock.unlock() }

        // A new format description means the stream restarted. Frames across
        // that boundary are not concatenable, so start a segment — and only
        // ever start one on a keyframe, or the segment opens undecodable.
        if let current = segments.last, CMFormatDescriptionEqual(current.format, otherFormatDescription: format) {
            current.frames.append(frame)
            current.bytes += frame.bytes
        } else {
            guard frame.isKey else { return }   // wait for the next IDR
            if !segments.isEmpty { segmentBreaks += 1 }
            let segment = Segment(format: format)
            segment.frames.append(frame)
            segment.bytes = frame.bytes
            segments.append(segment)
        }
        videoBytes += frame.bytes
        trimLocked(newest: pts)
    }

    func append(audio sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid && pts.isNumeric else { return }
        let bytes = CMSampleBufferGetTotalSampleSize(sample)
        lock.lock(); defer { lock.unlock() }
        audio.append((sample, pts, bytes))
        audioBytes += bytes
        trimAudioLocked(newest: pts)
    }

    // MARK: - Trim

    private func trimLocked(newest: CMTime) {
        // Drop whole segments that are entirely older than the window.
        while segments.count > 1, let oldest = segments.first,
              let last = oldest.frames.last,
              CMTimeGetSeconds(CMTimeSubtract(newest, last.pts)) > window {
            videoBytes -= oldest.bytes
            segments.removeFirst()
        }

        guard let current = segments.last else { return }

        // Within the newest segment, keep the LAST keyframe that still leaves a
        // full window behind it. Trimming to any other frame would produce a
        // clip that opens on a P-frame and cannot be decoded.
        var cut = 0
        for (index, frame) in current.frames.enumerated() where frame.isKey {
            if CMTimeGetSeconds(CMTimeSubtract(newest, frame.pts)) >= window { cut = index }
            else { break }
        }
        if cut > 0 {
            let dropped = current.frames[0..<cut].reduce(0) { $0 + $1.bytes }
            current.frames.removeFirst(cut)
            current.bytes -= dropped
            videoBytes -= dropped
        }

        // Hard ceiling. A five-minute window at a fight's bitrate is bigger than
        // a five-minute window docked, so the window alone is not a memory bound.
        while videoBytes + audioBytes > byteCap {
            guard let current = segments.last, current.frames.count > 1 else { break }
            // Evict a whole leading GOP so what remains still starts on a key.
            var next = 1
            while next < current.frames.count && !current.frames[next].isKey { next += 1 }
            guard next < current.frames.count else { break }
            let dropped = current.frames[0..<next].reduce(0) { $0 + $1.bytes }
            current.frames.removeFirst(next)
            current.bytes -= dropped
            videoBytes -= dropped
            cappedEvictions += 1
        }
    }

    private func trimAudioLocked(newest: CMTime) {
        // Keep a little more audio than video: the tap's timestamps trail
        // ScreenCaptureKit's by a few tens of milliseconds.
        let keep = window + 1.0
        var cut = 0
        while cut < audio.count,
              CMTimeGetSeconds(CMTimeSubtract(newest, audio[cut].pts)) > keep { cut += 1 }
        if cut > 0 {
            audioBytes -= audio[0..<cut].reduce(0) { $0 + $1.bytes }
            audio.removeFirst(cut)
        }
    }

    // MARK: - Snapshot

    /// Everything currently held, from the newest segment only.
    ///
    /// If the window spans a segment boundary the clip is short rather than
    /// re-encoded — and says so, instead of silently handing back less than
    /// was asked for.
    func snapshot() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let segment = segments.last,
              let first = segment.frames.first,
              let last = segment.frames.last else { return nil }

        let seconds = CMTimeGetSeconds(CMTimeSubtract(last.pts, first.pts))
        let audioSlice = audio.filter {
            CMTimeCompare($0.pts, first.pts) >= 0 && CMTimeCompare($0.pts, last.pts) <= 0
        }.map(\.sample)

        return Snapshot(format: segment.format,
                        video: segment.frames,
                        audio: audioSlice,
                        cutoff: last.pts,
                        seconds: seconds,
                        coversFullWindow: seconds >= window - 1.5)
    }
}
