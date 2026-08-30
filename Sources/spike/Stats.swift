import Foundation
import CoreMedia

/// Everything the spike exists to measure. A spike that does not report numbers
/// is just a toy.
final class Stats {
    private let lock = NSLock()

    // video
    var framesWritten = 0
    var framesSkippedNotComplete = 0   // SCK .idle/.blank — expected while docked
    var framesDroppedNotReady = 0      // writer input backed up: the bad one
    private var framesThisSecond = 0
    private(set) var lastSecondFPS = 0.0

    // audio
    var audioBuffers = 0
    var audioDropped = 0
    private var rmsAccumulator: Float = 0
    private var rmsCount = 0
    private(set) var lastSecondRMS: Float = 0
    var everHeardSound = false

    // sync
    private(set) var lastDriftSeconds: Double = 0
    var maxAbsDriftSeconds: Double = 0

    var lastVideoPTS: CMTime = .invalid
    var lastAudioPTS: CMTime = .invalid

    var markers: [(String, CMTime)] = []

    func countVideoFrame() {
        lock.lock(); framesWritten += 1; framesThisSecond += 1; lock.unlock()
    }

    func countAudio(rms: Float) {
        lock.lock()
        audioBuffers += 1
        rmsAccumulator += rms
        rmsCount += 1
        if rms > 0.0001 { everHeardSound = true }
        lock.unlock()
    }

    func noteDrift() {
        lock.lock(); defer { lock.unlock() }
        guard lastVideoPTS.isValid, lastAudioPTS.isValid else { return }
        let d = CMTimeGetSeconds(CMTimeSubtract(lastAudioPTS, lastVideoPTS))
        guard d.isFinite else { return }
        lastDriftSeconds = d
        maxAbsDriftSeconds = max(maxAbsDriftSeconds, abs(d))
    }

    /// Roll the per-second window.
    func roll() -> (fps: Double, level: String) {
        lock.lock()
        lastSecondFPS = Double(framesThisSecond)
        framesThisSecond = 0
        lastSecondRMS = rmsCount > 0 ? rmsAccumulator / Float(rmsCount) : 0
        rmsAccumulator = 0; rmsCount = 0
        let fps = lastSecondFPS
        let rms = lastSecondRMS
        lock.unlock()
        return (fps, rms > 0 ? String(format: "%6.1f dBFS", 20 * log10(rms)) : "  -inf dBFS")
    }
}
