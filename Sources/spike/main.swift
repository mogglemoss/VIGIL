import Foundation
import AppKit
import AVFoundation
import CoreMedia
import Carbon.HIToolbox

// ─────────────────────────────────────────────────────────────────────────────
// observance
//
// ScreenCaptureKit -> VideoToolbox -> a segmented in-memory ring. Nothing
// reaches the disk until you press the key.
//
// ⌥⌘S opens a clip containing everything currently buffered AND keeps
// recording live until you press it again. Video is muxed passthrough, so
// saving five buffered minutes costs about a second and re-encodes nothing.
// ─────────────────────────────────────────────────────────────────────────────

final class Controller: NSObject, NSApplicationDelegate {
    let config: Config
    let stats = Stats()
    let video = VideoCapture()
    let tap = AudioTap()
    let encoder = Encoder()
    let overlay = Overlay()
    var ring: ReplayBuffer!

    /// Guards the handoff between the ring and an open clip. Without it, a
    /// frame encoded between snapshotting the ring and the clip existing falls
    /// into a gap and goes missing from the middle of the save.
    private let clipLock = NSLock()
    private var clip: ClipWriter?
    private var clipCutoff = CMTime.zero
    private var clipStartedAt = Date()

    var ticker: DispatchSourceTimer?
    var startedAt = Date()
    var stopping = false
    var clipsSaved = 0

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
            ring = ReplayBuffer(window: config.length,
                                byteCap: Int(config.capGB * 1_073_741_824))

            try tap.start(mode: config.audio) { [weak self] sample, rms in
                guard let self else { return }
                self.stats.lastAudioPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                self.stats.countAudio(rms: rms)
                self.stats.noteDrift()
                self.clipLock.lock()
                self.ring.append(audio: sample)
                self.clip?.append(audio: sample)
                self.clipLock.unlock()
            }

            await overlay.prepare()
            try await video.start(config: config)

            let bitrate = config.bitrate ?? Int(Double(video.pixelWidth * video.pixelHeight)
                                                * Double(config.fps) * config.bitsPerPixel)
            try encoder.start(width: video.pixelWidth, height: video.pixelHeight,
                              fps: config.fps, codec: config.codec, bitrate: bitrate)

            encoder.onEncoded = { [weak self] sample in
                guard let self else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                self.clipLock.lock()
                self.ring.append(video: sample)
                if let clip = self.clip, CMTimeCompare(pts, self.clipCutoff) > 0 {
                    clip.append(video: sample)
                }
                self.clipLock.unlock()
                self.stats.lastVideoPTS = pts
                self.stats.countVideoFrame()
            }

            let frameDuration = CMTime(value: 1, timescale: config.fps)
            video.onSkippedIncomplete = { [weak self] in
                self?.stats.framesSkippedNotComplete += 1
            }
            video.onStop = { [weak self] error in
                Log.fail("ScreenCaptureKit stopped: \(error.localizedDescription)")
                self?.finish()
            }
            video.onFrame = { [weak self] sample in
                guard let self, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
                self.encoder.encode(pixels,
                                    pts: CMSampleBufferGetPresentationTimeStamp(sample),
                                    duration: frameDuration)
            }

            preflight(bitrate: bitrate)
            overlay.flash("● BUFFERING", seconds: 2.2)
            startedAt = Date()
            startTicker()
            if config.selfTest { Task { await self.runSelfTest() } }

        } catch {
            Log.fail(error.localizedDescription)
            Log.raw("")
            diagnose(error)
            exit(1)
        }
    }

    // MARK: - Clips

    func toggleClip() {
        if clip != nil { Task { await stopClip() } } else { startClip() }
    }

    func startClip() {
        clipLock.lock()
        guard clip == nil, let snapshot = ring?.snapshot() else {
            clipLock.unlock()
            overlay.flash("… NOTHING BUFFERED YET")
            return
        }
        do {
            let url = config.outputDir.appendingPathComponent(Self.filename())
            let writer = try ClipWriter(url: url, snapshot: snapshot, audioASBD: tap.asbd, audioFormat: tap.formatDescription)
            clip = writer
            clipCutoff = snapshot.cutoff
            clipStartedAt = Date()
            clipLock.unlock()

            let from = String(format: "%.0f", snapshot.seconds)
            overlay.flash("● CLIP  from -\(from)s", seconds: 2.4)
            Log.good("clip open — \(from) s of buffer, recording live → \(url.lastPathComponent)")
            if !snapshot.coversFullWindow {
                Log.warn("buffer held \(from) s, not the full \(Int(config.length)) s "
                         + "(started recently, or a segment break)")
            }
        } catch {
            clipLock.unlock()
            Log.fail("could not open clip: \(error.localizedDescription)")
            overlay.flash("✗ CLIP FAILED")
        }
    }

    /// Detaching the writer is synchronous on purpose: taking a lock across an
    /// await suspension is how you deadlock later.
    private func takeClip() -> ClipWriter? {
        clipLock.lock(); defer { clipLock.unlock() }
        let writer = clip
        clip = nil
        return writer
    }

    func stopClip() async {
        guard let writer = takeClip() else { return }

        let live = Date().timeIntervalSince(clipStartedAt)
        overlay.flash("■ SAVING…", seconds: 1.4)
        let began = Date()
        let result = await writer.finish()
        let took = Date().timeIntervalSince(began)
        clipsSaved += 1

        overlay.flash(String(format: "■ SAVED  %.0fs", result.seconds), seconds: 2.4)
        Log.good(String(format: "saved %.1f s (%.0f s buffered + %.0f s live) · %.0f MB · muxed in %.2f s",
                        result.seconds, writer.startedFrom, live,
                        Double(result.bytes) / 1_048_576, took))
        Log.raw("           \(result.url.path)")
        if writer.framesRejected > 0 {
            Log.warn("\(writer.framesRejected) frames rejected by the muxer")
        }
    }

    static func filename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "clip-\(formatter.string(from: Date())).mp4"
    }

    /// --selftest. Fills the ring, saves a clip, and checks the file that came
    /// out — the whole path, without needing anyone to press a key.
    func runSelfTest() async {
        let fill = config.length + 3
        Log.info(String(format: "selftest: filling the ring for %.0f s", fill))
        try? await Task.sleep(nanoseconds: UInt64(fill * 1_000_000_000))

        let held = ring.heldSeconds
        startClip()
        Log.info("selftest: recording live for 5 s")
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await stopClip()

        // Do not trust the counters. Open the file.
        let clips = (try? FileManager.default.contentsOfDirectory(at: config.outputDir,
                                                                  includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "mp4" }.sorted { $0.path > $1.path } ?? []
        guard let newest = clips.first else {
            Log.fail("selftest: no clip was written"); finish(); return
        }
        let asset = AVURLAsset(url: newest)
        let tracks = (try? await asset.load(.tracks)) ?? []
        var videoSeconds = 0.0, audioSeconds = 0.0
        for track in tracks {
            let d = (try? await track.load(.timeRange).duration).map(CMTimeGetSeconds) ?? 0
            if track.mediaType == .video { videoSeconds = d }
            if track.mediaType == .audio { audioSeconds = d }
        }
        let expected = held + 5
        let ok = tracks.count == 2 && videoSeconds > expected * 0.7 && audioSeconds > 0

        Log.raw("""

        ┌─ selftest ──────────────────────────────────────────────────────
        │ buffered   \(String(format: "%.1f", held)) s held when the clip opened
        │ expected   ~\(String(format: "%.1f", expected)) s  (buffer + 5 s live)
        │ got        \(tracks.count) tracks · video \(String(format: "%.1f", videoSeconds)) s · audio \(String(format: "%.1f", audioSeconds)) s
        │ verdict    \(ok ? "✓ the past really is in the clip" : "✗ clip is short or missing a track")
        └─────────────────────────────────────────────────────────────────
        """)
        finish()
    }

    // MARK: - Preflight

    func preflight(bitrate: Int) {
        let audioLine: String
        switch config.audio {
        case .processes(let ids): audioLine = "mixdown of \(ids.joined(separator: ", "))"
        case .globalExcludingSelf: audioLine = "everything, minus this process"
        }
        let projected = Double(bitrate) / 8 * config.length / 1_073_741_824
        Log.raw("""

        ┌─ observance ────────────────────────────────────────────────────
        │ display   \(video.displayDescription)  →  capture \(video.pixelWidth)×\(video.pixelHeight) @ \(config.fps)
        │ codec     \(config.codec == .hevc ? "hevc" : "h264")  \(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mbps  ·  1 s keyframes  ·  no B-frames
        │ replay    \(Int(config.length)) s in memory  ·  ~\(String(format: "%.1f", projected)) GB at full bitrate  ·  cap \(String(format: "%g", config.capGB)) GB
        │ audio     \(audioLine)
        │ overlay   \(video.excludedSelf ? "excluded from capture" : "NOT excluded — it will be in your clips")
        │ output    \(config.outputDir.path)
        │ hotkeys   ⌥⌘S start / stop a clip   ·   ⌥⌘Q quit
        └─────────────────────────────────────────────────────────────────

        Nothing reaches the disk until you press ⌥⌘S. That opens a clip with
        everything buffered and keeps recording; press it again to save.

        """)
    }

    // MARK: - Ticker

    func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopping, let ring = self.ring else { return }
            let rolled = self.stats.roll()
            let state = self.clip == nil
                ? String(format: "buffer %3.0f/%.0f s", ring.heldSeconds, self.config.length)
                : String(format: "CLIP   %3.0f s", Date().timeIntervalSince(self.clipStartedAt))
            Log.raw(String(format: "[%@] %@  %5.2f GB   %5.1f fps  idle %d   audio %@   a/v %+.0f ms",
                           Log.stamp, state,
                           Double(ring.bytes) / 1_073_741_824,
                           rolled.fps, self.stats.framesSkippedNotComplete,
                           rolled.level, self.stats.lastDriftSeconds * 1000))

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
        let clipOK = Hotkeys.register(id: 1, keyCode: UInt32(kVK_ANSI_S), modifiers: mods) { [weak self] in
            Hotkeys.confirm()
            self?.toggleClip()
        }
        let quitOK = Hotkeys.register(id: 2, keyCode: UInt32(kVK_ANSI_Q), modifiers: mods) { [weak self] in
            self?.finish()
        }
        if !clipOK || !quitOK {
            Log.warn("a hotkey failed to register — something else owns ⌥⌘S or ⌥⌘Q")
        }
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in self?.finish() }
        source.resume()
        signalSource = source
    }
    var signalSource: DispatchSourceSignal?

    // MARK: - Diagnostics

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

        ♪ = producing output right now. Only these can be tapped.
        EVE's client reports no bundle id — it is the one called exefile.
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
        Log.info(String(format: "observed %.0f frames/s over the wall clock (ASBD claims %.0f)",
                        tap.observedSampleRate, tap.asbd.mSampleRate))
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

    func diagnose(_ error: Error) {
        let text = error.localizedDescription.lowercased()
        if text.contains("processtap") || text.contains("aggregate") || text.contains("matched") {
            Log.raw("""
            Audio setup failed before capture started. Most likely:
              · EVE is not running, or is running but has not played a sound yet —
                a process only appears in the audio process list once it opens an
                output stream. Undock, or use --audio all. Run --list to see.
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

    // MARK: - Finish

    func finish() {
        guard !stopping else { return }
        stopping = true
        ticker?.cancel()
        Task {
            if clip != nil {
                Log.info("a clip was still open — saving it")
                await stopClip()
            }
            await video.stop()
            encoder.stop()
            tap.stop()
            summary()
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(0)
        }
    }

    func summary() {
        let seconds = Date().timeIntervalSince(startedAt)
        let fps = seconds > 0 ? Double(stats.framesWritten) / seconds : 0
        Log.raw("""

        ┌─ session ───────────────────────────────────────────────────────
        │ ran        \(String(format: "%.0f", seconds)) s  ·  \(stats.framesWritten) frames encoded  ·  \(String(format: "%.1f", fps)) fps
        │ ring       held \(String(format: "%.0f", ring?.heldSeconds ?? 0)) s  ·  \(String(format: "%.2f", Double(ring?.bytes ?? 0) / 1_073_741_824)) GB
        │            \(ring?.segmentBreaks ?? 0) segment breaks  ·  \(ring?.cappedEvictions ?? 0) evictions at the memory cap
        │ audio      \(stats.audioBuffers) buffers  ·  max |drift| \(String(format: "%.0f", stats.maxAbsDriftSeconds * 1000)) ms
        │ clips      \(clipsSaved) saved → \(config.outputDir.path)
        └─────────────────────────────────────────────────────────────────
        """)
        Log.raw("")
    }
}

// ── entry ────────────────────────────────────────────────────────────────────

let config = Config.parse(Array(CommandLine.arguments.dropFirst()))
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon, no menu bar, no stealing focus
let controller = Controller(config: config)
app.delegate = controller
app.run()
