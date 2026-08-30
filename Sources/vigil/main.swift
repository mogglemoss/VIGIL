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
    let menuBar = MenuBar()
    let about = About()
    let preferences = Preferences()
    lazy var outputDirectory = config.outputDir
    var lastClip: URL?
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
        if !config.listOnly && !config.checkOnly { installMenuBar() }
        installHotkeys()
        Task { await self.start() }
    }

    // MARK: - Start

    func start() async {
        if let directory = config.overlaySample {
            await overlay.sample(into: directory)
            await about.sample(into: directory)
            await preferences.sample(into: directory)
            // Open and close both sheets for real. A window that releases
            // itself on close, while we also hold it, takes the whole app down
            // — and only the closing proves it.
            await MainActor.run {
                about.show(); about.close()
                preferences.show(); preferences.close()
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            Log.good("both sheets opened and closed without incident")
            Log.good("overlay states and the about screen written to \(directory.path)")
            exit(0)
        }
        if config.listOnly { listAudioProcesses(); return }
        if config.checkOnly { await checkAudioOnly(); return }
        do {
            try FileManager.default.createDirectory(at: config.outputDir,
                                                    withIntermediateDirectories: true)
            ring = ReplayBuffer(window: config.length,
                                byteCap: Int(config.capGB * 1_073_741_824))

            tap.onFormatChange = { [weak self] in
                self?.ring?.flushAudio()
                if self?.clip != nil {
                    Log.warn("a clip was open when the audio format changed — "
                             + "its audio ends here; the video does not")
                }
            }
            tap.onStateChange = { [weak self] state in
                guard let self else { return }
                switch state {
                case .attached(let count):
                    self.stats.breakAudioContinuity()
                    self.overlay.flash("Observing", stamp: "Audio on \(count) process(es)",
                                       tint: Overlay.Ink.sage)
                case .waitingForProcesses:
                    self.stats.breakAudioContinuity()
                    self.overlay.flash("Observing", stamp: "Audio awaiting EVE",
                                       tint: Overlay.Ink.fog)
                case .failed(let why):
                    self.overlay.flash("Observing", stamp: "Audio failed",
                                       tint: Overlay.Ink.blood)
                    Log.fail("audio: \(why)")
                }
            }
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
            overlay.flash("Observing", stamp: "Buffer live", seconds: 2.4)
            startedAt = Date()
            startTicker()
            if config.selfTest { Task { await self.runSelfTest() } }

        } catch {
            Notify.fatal("VIGIL could not stand the watch", remedy(for: error))
            exit(1)
        }
    }

    /// One message that works read in a terminal or read in a dialog.
    func remedy(for error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("processtap") || text.contains("aggregate") || text.contains("matched") {
            return """
            \(error.localizedDescription)

            The audio tap could not be built. Most likely EVE is not running, or \
            is running and has not played a sound yet — a process only appears to \
            Core Audio once it has opened an output stream. Undock, or set Audio \
            to "Everything the Mac plays" in Standing Orders.

            If that is not it, System Audio Recording was refused. Grant it in \
            System Settings › Privacy & Security, or reset the request with:

                tccutil reset AudioCapture app.observance.vigil
            """
        }
        return """
        \(error.localizedDescription)

        The display could not be captured. Grant Screen Recording to VIGIL in \
        System Settings › Privacy & Security › Screen & System Audio Recording.

        If you declined once already, macOS remembers and will not ask again. \
        Reset the request with:

            tccutil reset ScreenCapture app.observance.vigil
        """
    }

    func installMenuBar() {
        menuBar.clipsDirectory = config.outputDir
        menuBar.readState = { [weak self] in
            guard let self else { return MenuBar.State() }
            var state = MenuBar.State()
            state.observing = self.ring != nil
            state.clipping = self.clip != nil
            state.heldSeconds = self.ring?.heldSeconds ?? 0
            state.windowSeconds = self.ring?.window ?? self.config.length
            state.clipSeconds = self.clip == nil ? 0 : Date().timeIntervalSince(self.clipStartedAt)
            state.gigabytes = Double(self.ring?.bytes ?? 0) / 1_073_741_824
            state.clipsSaved = self.clipsSaved
            state.lastClip = self.lastClip
            switch self.config.audio {
            case .processes(let ids): state.audioDescription = ids.joined(separator: " + ")
            case .globalExcludingSelf: state.audioDescription = "all audio"
            }
            if case .attached = self.tap.state { state.audioAttached = true }
            else { state.audioAttached = false }
            return state
        }
        menuBar.onToggleClip = { [weak self] in self?.toggleClip() }
        menuBar.onQuit = { [weak self] in self?.finish() }
        menuBar.onAbout = { [weak self] in self?.about.show() }
        menuBar.onPreferences = { [weak self] in self?.preferences.show() }
        menuBar.onSetLength = { [weak self] seconds in
            guard let self else { return }
            self.ring?.setWindow(seconds)
            Log.info("replay length now \(Int(seconds)) s")
            self.overlay.flash("Observing", stamp: "\(Int(seconds)) s held",
                               tint: Overlay.Ink.sage)
        }
        preferences.onHotKeyChanged = { [weak self] chord in
            guard self != nil else { return false }
            let previous = Settings.recordHotKey
            return Hotkeys.rebind(id: 1, keyCode: chord.keyCode, modifiers: chord.modifiers,
                                  fallbackKeyCode: previous.keyCode,
                                  fallbackModifiers: previous.modifiers)
        }
        preferences.onLengthChanged = { [weak self] seconds in
            self?.ring?.setWindow(seconds)
            Log.info("replay length now \(Int(seconds)) s")
        }
        preferences.onFolderChanged = { [weak self] url in
            self?.outputDirectory = url
            self?.menuBar.clipsDirectory = url
            Log.info("clips now filed to \(url.path)")
        }
        preferences.onRestartNeeded = { [weak self] in
            self?.overlay.flash("Vigil", stamp: "Order filed", tint: Overlay.Ink.fog)
        }
        menuBar.install()
    }

    // MARK: - Clips

    func toggleClip() {
        if clip != nil { Task { await stopClip() } } else { startClip() }
    }

    func startClip() {
        clipLock.lock()
        guard clip == nil, let snapshot = ring?.snapshot() else {
            clipLock.unlock()
            overlay.flash("Observing", stamp: "Nothing held", tint: Overlay.Ink.fog)
            return
        }
        do {
            let url = outputDirectory.appendingPathComponent(Self.filename())
            let writer = try ClipWriter(url: url, snapshot: snapshot, audioASBD: tap.asbd, audioFormat: tap.formatDescription)
            clip = writer
            clipCutoff = snapshot.cutoff
            clipStartedAt = Date()
            clipLock.unlock()

            if !writer.hasAudio {
                Log.warn("no audio tap attached — this clip is video only")
            }
            Chime.latch.play()
            let from = String(format: "%.0f", snapshot.seconds)
            overlay.flash("Witnessing", stamp: "from −\(from) s",
                          tint: Overlay.Ink.bright, seconds: 2.4)
            Log.good("clip open — \(from) s of buffer, recording live → \(url.lastPathComponent)")
            if !snapshot.coversFullWindow {
                Log.warn("buffer held \(from) s, not the full \(Int(config.length)) s "
                         + "(started recently, or a segment break)")
            }
        } catch {
            clipLock.unlock()
            Log.fail("could not open clip: \(error.localizedDescription)")
            overlay.flash("Not filed", stamp: "Failed", tint: Overlay.Ink.blood)
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
        overlay.flash("Filing", stamp: "in hand", tint: Overlay.Ink.fog, seconds: 1.4)
        let began = Date()
        let result = await writer.finish()
        let took = Date().timeIntervalSince(began)
        clipsSaved += 1
        lastClip = result.url

        Chime.stamp.play()
        overlay.flash("Filed", stamp: String(format: "%.0f s", result.seconds),
                      tint: Overlay.Ink.sage, seconds: 2.6)
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

        ┌─ vigil ─────────────────────────────────────────────────────────
        │ display   \(video.displayDescription)  →  capture \(video.pixelWidth)×\(video.pixelHeight) @ \(config.fps)
        │ codec     \(config.codec == .hevc ? "hevc" : "h264")  \(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mbps  ·  1 s keyframes  ·  no B-frames
        │ replay    \(Int(config.length)) s in memory  ·  ~\(String(format: "%.1f", projected)) GB at full bitrate  ·  cap \(String(format: "%g", config.capGB)) GB
        │ audio     \(audioLine)
        │ overlay   \(video.excludedSelf ? "excluded from capture" : "NOT excluded — it will be in your clips")
        │ output    \(config.outputDir.path)
        │ hotkeys   \(Settings.recordHotKey.label) strike / file   ·   ⌥⌘Q quit  (also in the menu bar)
        └─────────────────────────────────────────────────────────────────

        Nothing reaches the disk until you press \(Settings.recordHotKey.label). That opens a clip with
        everything buffered and keeps recording; press it again to save.

        """)
    }

    // MARK: - Ticker

    func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopping, let ring = self.ring else { return }
            self.menuBar.refresh()
            let rolled = self.stats.roll()
            let state = self.clip == nil
                ? String(format: "buffer %3.0f/%.0f s", ring.heldSeconds, ring.window)
                : String(format: "CLIP   %3.0f s", Date().timeIntervalSince(self.clipStartedAt))
            let audioColumn: String
            switch self.tap.state {
            case .attached:           audioColumn = rolled.level
            case .waitingForProcesses: audioColumn = "  awaiting"
            case .failed:             audioColumn = "    failed"
            }
            Log.raw(String(format: "[%@] %@  %5.2f GB   %5.1f fps  idle %d   audio %@   a/v %+.0f ms",
                           Log.stamp, state,
                           Double(ring.bytes) / 1_073_741_824,
                           rolled.fps, self.stats.framesSkippedNotComplete,
                           audioColumn, self.stats.lastDriftSeconds * 1000))

            if self.stats.audioBuffers > 0 && !self.stats.everHeardSound
                && Date().timeIntervalSince(self.startedAt) > 8 {
                self.overlay.flash("Observing", stamp: "No audio heard",
                                   tint: Overlay.Ink.blood, seconds: 3)
                Notify.onceIfSilent("silent-tap",
                    title: "VIGIL is recording silence",
                    message: """
                    The audio tap is delivering buffers and every sample in them is \
                    zero. That is what a denied System Audio Recording grant looks \
                    like — Core Audio reports no error for it.

                    Grant it in System Settings › Privacy & Security › Screen & \
                    System Audio Recording, or reset the request with:

                        tccutil reset AudioCapture app.observance.vigil

                    The watch will keep standing. Your clips will have no sound.
                    """)
            }
        }
        timer.resume()
        ticker = timer
    }

    // MARK: - Hotkeys

    func installHotkeys() {
        let chord = Settings.recordHotKey
        let clipOK = Hotkeys.register(id: 1, keyCode: chord.keyCode,
                                      modifiers: chord.modifiers) { [weak self] in
            self?.toggleClip()
        }
        let quitOK = Hotkeys.register(id: 2, keyCode: UInt32(kVK_ANSI_Q),
                                      modifiers: UInt32(optionKey | cmdKey)) { [weak self] in
            self?.finish()
        }
        if !clipOK {
            Log.warn("\(chord.label) is already spoken for — rebind it in Standing Orders")
        }
        if !quitOK { Log.warn("⌥⌘Q is already spoken for") }
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
            Notify.fatal("VIGIL could not open the tap", remedy(for: error))
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

                tccutil reset AudioCapture app.observance.vigil

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
        │ clips      \(clipsSaved) saved → \(outputDirectory.path)
        └─────────────────────────────────────────────────────────────────
        """)
        Log.raw("")
    }
}

// ── entry ────────────────────────────────────────────────────────────────────

Settings.registerDefaults()
let config = Config.parse(Array(CommandLine.arguments.dropFirst()))

// Diagnostics may run alongside a standing watch; a second watch may not.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon, no menu bar, no stealing focus

// Diagnostics may run alongside a standing watch; a second watch may not.
if config.listOnly == false && config.checkOnly == false && config.overlaySample == nil,
   let held = SingleInstance.claim() {
    let who = held.pid.map { " (process \($0))" } ?? ""
    Notify.fatal("A watch is already standing\(who)", """
        Two instances both capture the display, which costs frame rate, and both \
        claim the same chord — the second registration succeeds without complaint, \
        so a keypress goes to whichever the window server prefers and you cannot \
        tell which watch you struck.

        Close the standing watch from its menu bar, or run:

            pkill -f VIGIL
        """)
    exit(1)
}

let controller = Controller(config: config)
app.delegate = controller
app.run()
