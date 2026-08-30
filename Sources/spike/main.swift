import Foundation
import AppKit
import AVFoundation
import CoreMedia
import Carbon.HIToolbox

// ─────────────────────────────────────────────────────────────────────────────
// observance spike
//
// Answers four questions and nothing else:
//   1. Can ScreenCaptureKit pull the display at 60 fps while EVE is fullscreen,
//      without costing EVE frames?
//   2. Does a Core Audio process tap actually produce non-zero samples?
//      (TCC denial is silent — noErr and buffers of zeros.)
//   3. Do tap timestamps line up with SCK frame timestamps?
//   4. Does a Carbon hotkey fire while EVE holds fullscreen focus?
//
// No ring buffer. No UI. No menu bar. Those are v1, and they are only worth
// building if the answers above are yes.
// ─────────────────────────────────────────────────────────────────────────────

final class Controller: NSObject, NSApplicationDelegate {
    let config: Config
    let stats = Stats()
    let video = VideoCapture()
    let tap = AudioTap()
    let overlay = Overlay()
    var writer: Writer?
    var ticker: DispatchSourceTimer?
    var startedAt = Date()
    var stopping = false

    init(config: Config) { self.config = config }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installHotkeys()
        Task { await self.start() }
    }

    // MARK: - Start

    func start() async {
        if config.listOnly { listAudioProcesses(); return }
        if config.checkOnly { await checkAudioOnly(); return }
        do {
            try FileManager.default.createDirectory(at: config.outputDir,
                                                    withIntermediateDirectories: true)

            // Audio first: it is the likeliest thing to be refused, and failing
            // before we have created a video file keeps the failure legible.
            var heardAnything = false
            try tap.start(mode: config.audio) { [weak self] sample, rms in
                guard let self, let writer = self.writer else { return }
                heardAnything = heardAnything || rms > 0
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                switch writer.appendAudio(sample) {
                case .wrote:
                    self.stats.lastAudioPTS = pts
                    self.stats.countAudio(rms: rms)
                    self.stats.noteDrift()
                case .notStarted:
                    break                    // before the first video frame; fine
                case .notReady:
                    self.stats.audioDropped += 1
                case .failed:
                    self.stats.audioDropped += 1
                }
            }

            try await video.start(config: config)

            let bitrate = config.bitrate ?? Int(Double(video.pixelWidth * video.pixelHeight)
                                                * Double(config.fps) * config.bitsPerPixel)
            let url = config.outputDir.appendingPathComponent(Self.filename())
            let writer = try Writer(url: url,
                                    width: video.pixelWidth, height: video.pixelHeight,
                                    fps: config.fps, codec: config.codec, bitrate: bitrate,
                                    audioASBD: tap.asbd)
            self.writer = writer

            video.onSkippedIncomplete = { [weak self] in
                self?.stats.framesSkippedNotComplete += 1
            }
            video.onStop = { [weak self] error in
                Log.fail("ScreenCaptureKit stopped: \(error.localizedDescription)")
                self?.finish()
            }
            video.onFrame = { [weak self] sample in
                guard let self, let writer = self.writer else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard writer.startSessionIfNeeded(at: pts) else { return }
                switch writer.appendVideo(sample) {
                case .wrote:
                    self.stats.lastVideoPTS = pts
                    self.stats.countVideoFrame()
                case .notReady:
                    self.stats.framesDroppedNotReady += 1
                case .failed:
                    self.stats.framesDroppedNotReady += 1
                case .notStarted:
                    break
                }
            }

            preflight(bitrate: bitrate, url: url)
            overlay.flash("● RECORDING", seconds: 2.2)
            startedAt = Date()
            startTicker()

        } catch {
            Log.fail(error.localizedDescription)
            Log.raw("")
            diagnose(error)
            exit(1)
        }
    }

    /// --list. A process is only tappable once it has opened an output stream,
    /// so "not listed" and "not running" are different problems.
    func listAudioProcesses() {
        let objects = AudioProcesses.all()
        Log.raw("\n\(objects.count) audio processes\n")
        var rows: [(String, String, Bool)] = []
        for object in objects {
            let pid = AudioProcesses.pid(of: object)
            let exe = pid.flatMap { AudioProcesses.executableName(forPID: $0) } ?? "?"
            let bid = AudioProcesses.bundleID(of: object) ?? "—"
            rows.append((bid, "\(exe) [pid \(pid.map(String.init) ?? "?")]",
                         AudioProcesses.isRunningOutput(object)))
        }
        for (bid, exe, live) in rows.sorted(by: { $0.1.lowercased() < $1.1.lowercased() }) {
            Log.raw("  \(live ? "♪" : " ") \(exe.padding(toLength: max(38, exe.count), withPad: " ", startingAt: 0))  \(bid)")
        }
        Log.raw("""

        ♪ = producing output right now. Only these can be tapped by bundle id.
        If EVE is absent entirely, it has never opened an output stream this
        session — undock, or turn the sound on in EVE's audio settings.
        """)
        Log.raw("")
        exit(0)
    }

    /// --check. The tap fails silently when its grant is denied, so the only
    /// honest test is to listen to it and measure.
    func checkAudioOnly() async {
        Log.raw("\nplay something audible, then wait 5 s\n")
        do {
            try tap.start(mode: config.audio) { [weak self] _, rms in
                self?.stats.countAudio(rms: rms)
            }
        } catch {
            Log.fail(error.localizedDescription)
            Log.raw("")
            diagnose(error)
            exit(1)
        }
        Log.info("tap format: \(tap.describedAs)")
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        tap.stop()

        let peak = tap.peakRMS
        let db = peak > 0 ? String(format: "%.1f dBFS", 20 * log10(peak)) : "-inf"
        Log.raw("")
        if tap.buffersSeen == 0 {
            Log.fail("no buffers at all — the aggregate device never ran")
        } else if !stats.everHeardSound {
            Log.fail("\(tap.buffersSeen) buffers, every sample zero (peak \(db))")
            Log.raw("""

            Core Audio returned noErr the whole way through and handed you silence.
            That is exactly what a denied System Audio Recording grant looks like.

                tccutil reset AudioCapture app.observance.spike

            Then rerun and answer the prompt. If the prompt never appears, nothing
            was playing — a process only enters the tap once it opens an output
            stream, so undock EVE or play any sound first.
            """)
            exit(1)
        } else {
            Log.good("\(tap.buffersSeen) buffers, peak \(db) — the tap is live and carrying real signal")
        }
        Log.raw("")
        exit(0)
    }

    static func filename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "spike-\(f.string(from: Date())).mp4"
    }

    // MARK: - Preflight

    func preflight(bitrate: Int, url: URL) {
        let audioLine: String
        switch config.audio {
        case .processes(let ids): audioLine = "mixdown of \(ids.joined(separator: ", "))"
        case .globalExcludingSelf: audioLine = "everything, minus this process"
        }
        let playing = AudioProcesses.currentlyPlaying()

        Log.raw("""

        ┌─ observance spike ──────────────────────────────────────────────
        │ display   \(video.displayDescription)  →  capture \(video.pixelWidth)×\(video.pixelHeight) @ \(config.fps) (scale \(String(format: "%.2f", config.scale)))
        │ codec     \(config.codec == .hevc ? "hevc" : "h264")  \(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mbps  ·  1 s keyframes  ·  no B-frames
        │ audio     \(audioLine)
        │           tap format: \(tap.describedAs)
        │           making sound right now: \(playing.isEmpty ? "nothing" : playing.joined(separator: ", "))
        │ output    \(url.path)
        │ hotkeys   ⌥⌘S drop a marker   ·   ⌥⌘Q stop and save
        └─────────────────────────────────────────────────────────────────

        Go play. Press ⌥⌘S whenever something happens — that is the reliability
        test. Watch EVE's own frame rate, not this window.

        """)
    }

    // MARK: - Ticker

    func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let writer = self.writer, !self.stopping else { return }
            if writer.isFailed {
                Log.fail("writer failed: \(writer.failure?.localizedDescription ?? "unknown")")
                self.finish()
                return
            }
            Log.raw(self.stats.tick(fileBytes: writer.bytesOnDisk))

            if self.stats.audioBuffers > 0 && !self.stats.everHeardSound
                && Date().timeIntervalSince(self.startedAt) > 8 {
                Log.warn("tap is delivering buffers but every sample is zero — "
                         + "this is what a denied System Audio Recording grant looks like")
            }
        }
        timer.resume()
        ticker = timer
    }

    // MARK: - Hotkeys

    func installHotkeys() {
        let mods = UInt32(optionKey | cmdKey)
        let markOK = Hotkeys.register(id: 1, keyCode: UInt32(kVK_ANSI_S), modifiers: mods) { [weak self] in
            guard let self else { return }
            let at = self.stats.lastVideoPTS
            let elapsed = Date().timeIntervalSince(self.startedAt)
            self.stats.markers.append((Log.stamp, at))
            Hotkeys.confirm()
            self.overlay.flash("◆ MARKER \(self.stats.markers.count)   \(Log.stamp)")
            Log.good("marker \(self.stats.markers.count) at \(String(format: "%.1f", elapsed)) s")
        }
        let quitOK = Hotkeys.register(id: 2, keyCode: UInt32(kVK_ANSI_Q), modifiers: mods) { [weak self] in
            self?.overlay.flash("■ SAVED", seconds: 2.0)
            self?.finish()
        }
        if !markOK || !quitOK {
            Log.warn("a hotkey failed to register — something else owns ⌥⌘S or ⌥⌘Q")
        }

        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in self?.finish() }
        source.resume()
        signalSource = source
    }
    var signalSource: DispatchSourceSignal?

    // MARK: - Finish

    func finish() {
        guard !stopping else { return }
        stopping = true
        ticker?.cancel()
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await video.stop()
            tap.stop()
            await writer?.finish()
            await verdict()
            exit(0)
        }
    }

    func verdict() async {
        guard let writer else { return }
        let seconds = Date().timeIntervalSince(startedAt)
        let bytes = writer.bytesOnDisk

        // Do not trust the counters alone — open the file we actually produced.
        var videoDuration = 0.0, audioDuration = 0.0, trackCount = 0
        let asset = AVURLAsset(url: writer.url)
        if let tracks = try? await asset.load(.tracks) {
            trackCount = tracks.count
            for track in tracks {
                let d = (try? await track.load(.timeRange).duration).map(CMTimeGetSeconds) ?? 0
                if track.mediaType == .video { videoDuration = d }
                if track.mediaType == .audio { audioDuration = d }
            }
        }

        let fps = seconds > 0 ? Double(stats.framesWritten) / seconds : 0
        let mbps = seconds > 0 ? Double(bytes) * 8 / seconds / 1_000_000 : 0
        let peakDB = tap.peakRMS > 0 ? String(format: "%.1f dBFS", 20 * log10(tap.peakRMS)) : "-inf"
        let markerList = stats.markers.isEmpty
            ? "none pressed — did ⌥⌘S work under fullscreen EVE?"
            : stats.markers.map { $0.0 }.joined(separator: ", ")

        func verdictLine(_ ok: Bool, _ good: String, _ bad: String) -> String {
            ok ? "✓ \(good)" : "✗ \(bad)"
        }

        let captureOK = stats.framesDroppedNotReady == 0 && fps > Double(config.fps) * 0.9
        let audioOK = stats.everHeardSound && audioDuration > 0
        let syncOK = stats.maxAbsDriftSeconds < 0.05
        let fileOK = trackCount == 2 && videoDuration > 0 && audioDuration > 0

        Log.raw("""

        ┌─ verdict ───────────────────────────────────────────────────────
        │ ran        \(String(format: "%.1f", seconds)) s
        │
        │ video      \(stats.framesWritten) frames · \(String(format: "%.2f", fps)) fps average
        │            \(stats.framesDroppedNotReady) dropped (encoder fell behind)
        │            \(stats.framesSkippedNotComplete) idle frames skipped (expected when nothing moves)
        │            \(verdictLine(captureOK, "capture kept up", "capture could not keep up — try --scale 0.75"))
        │
        │ audio      \(stats.audioBuffers) buffers · peak \(peakDB) · \(stats.audioDropped) dropped
        │            \(verdictLine(audioOK, "tap is live and carrying real signal", "TAP PRODUCED SILENCE — see below"))
        │
        │ sync       max |drift| \(String(format: "%.1f", stats.maxAbsDriftSeconds * 1000)) ms
        │            \(verdictLine(syncOK, "audio and video share a clock", "drift is too large to ignore"))
        │
        │ file       \(String(format: "%.2f", Double(bytes) / 1_073_741_824)) GB · \(String(format: "%.0f", mbps)) Mbps
        │            \(trackCount) tracks · video \(String(format: "%.1f", videoDuration)) s · audio \(String(format: "%.1f", audioDuration)) s
        │            \(verdictLine(fileOK, "file has both tracks", "file is missing a track"))
        │            \(writer.url.path)
        │
        │ markers    \(markerList)
        └─────────────────────────────────────────────────────────────────
        """)

        if !audioOK {
            Log.raw("""

            The tap returned noErr throughout and still gave you silence. That is
            what a denied System Audio Recording grant looks like — Core Audio does
            not report it. Check System Settings › Privacy & Security › System Audio
            Recording, or delete the entry and rerun to get the prompt back:

                tccutil reset AudioCapture app.observance.spike
            """)
        }
        if !stats.markers.isEmpty && !captureOK {
            Log.raw("\nHotkeys worked but capture did not. Rerun with --scale 0.75 before "
                    + "concluding anything about the architecture.")
        }
        Log.raw("")
    }

    func diagnose(_ error: Error) {
        let text = error.localizedDescription.lowercased()
        if text.contains("processtap") || text.contains("aggregate") || text.contains("matched") {
            Log.raw("""
            Audio setup failed before capture started. Most likely:
              · EVE is not running, or is running but has not played a sound yet —
                a process only appears in the audio process list once it opens an
                output stream. Undock, or use --audio all.
              · System Audio Recording was refused. Rerun after:
                    tccutil reset AudioCapture app.observance.spike
            """)
        } else {
            Log.raw("""
            Capture setup failed. If this mentions declined or permission, grant
            Screen Recording to Observance Spike in System Settings › Privacy &
            Security › Screen & System Audio Recording, then rerun.

            If you already declined once, macOS remembers and will not ask again:

                tccutil reset ScreenCapture app.observance.spike
            """)
        }
    }
}

// ── entry ────────────────────────────────────────────────────────────────────

let config = Config.parse(Array(CommandLine.arguments.dropFirst()))
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon, no menu bar, no stealing focus
let controller = Controller(config: config)
app.delegate = controller
app.run()
