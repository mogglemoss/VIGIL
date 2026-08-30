import Foundation
import CoreAudio
import CoreMedia
import AVFoundation

/// A Core Audio process tap, read through a private aggregate device.
///
/// This is the piece ScreenCaptureKit cannot do: SCContentFilter couples audio
/// selection to video framing, so "whole display, but only EVE + Discord audio"
/// is unreachable through SCK. A tap decouples them.
final class AudioTap {

    struct Failure: LocalizedError {
        let stage: String
        let status: OSStatus
        var errorDescription: String? {
            "\(stage) failed (OSStatus \(status)\(Self.fourCC(status).map { " '\($0)'" } ?? ""))"
        }
        static func fourCC(_ s: OSStatus) -> String? {
            let v = UInt32(bitPattern: s)
            let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                         UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
            guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
            return String(bytes: bytes, encoding: .ascii)
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var formatDescription: CMFormatDescription?
    private(set) var asbd = AudioStreamBasicDescription()
    private(set) var describedAs = ""

    /// Set once the first buffer arrives, so the caller can tell "not started"
    /// from "started but silent".
    private(set) var buffersSeen: UInt64 = 0
    private(set) var peakRMS: Float = 0
    /// Ground truth: frames actually delivered per second of wall clock. If this
    /// disagrees with the ASBD, the ASBD is what is wrong.
    private(set) var framesDelivered: UInt64 = 0
    private var firstHostTime: UInt64 = 0
    private var lastHostTime: UInt64 = 0
    var observedSampleRate: Double {
        guard firstHostTime > 0, lastHostTime > firstHostTime else { return 0 }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(
            CMClockMakeHostTimeFromSystemUnits(lastHostTime),
            CMClockMakeHostTimeFromSystemUnits(firstHostTime)))
        return seconds > 0 ? Double(framesDelivered) / seconds : 0
    }

    private let queue = DispatchQueue(label: "app.observance.vigil.tap", qos: .userInitiated)
    /// Attach and detach are serialised here so a rebuild cannot race the
    /// process-list listener that triggered it.
    private let control = DispatchQueue(label: "app.observance.vigil.tap.control")
    private var onSample: ((CMSampleBuffer, Float) -> Void)?

    enum State: Equatable {
        case attached(processes: Int)
        case waitingForProcesses
        case failed(String)
    }

    private(set) var state = State.waitingForProcesses
    var onStateChange: ((State) -> Void)?
    /// Fires when a rebuild produced a different stream format. Buffered audio
    /// in the old format cannot be muxed alongside the new, so the ring has to
    /// drop it.
    var onFormatChange: (() -> Void)?

    private var mode: AudioMode = .globalExcludingSelf
    private var trackedProcesses: Set<AudioObjectID> = []
    private var listener: AudioObjectPropertyListenerBlock?
    private var pendingReconcile: DispatchWorkItem?
    /// Core Audio can hand back one more buffer as the IOProc is torn down, and
    /// its timestamp belongs to the old session. Letting that into the ring puts
    /// a half-second lie in the audio timeline that the gap-filler then pads out
    /// with silence. Stop accepting before we stop the device.
    private var accepting = false

    // MARK: - Setup

    func start(mode: AudioMode, onSample: @escaping (CMSampleBuffer, Float) -> Void) throws {
        self.onSample = onSample
        self.mode = mode
        try attach()
        watchProcessList()
    }

    private func attach() throws {
        let description = try makeTapDescription(mode)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw Failure(stage: "AudioHardwareCreateProcessTap", status: status)
        }

        asbd = try readTapFormat()
        try makeAggregateDevice(tapUID: description.uuid.uuidString)

        // kAudioTapPropertyFormat advertises the tap's nominal rate, not the
        // rate it will actually be clocked at. Once the tap sits in an
        // aggregate device, the device's rate wins — and if the machine's
        // output is set to 44.1 kHz while the tap claims 48 kHz, every
        // timestamp we derive is 8.8% too fast and the audio track ends up
        // that much shorter than the video. Believe the device.
        if let deviceRate = aggregateNominalSampleRate(), deviceRate > 0,
           abs(deviceRate - asbd.mSampleRate) > 1 {
            Log.warn(String(format: "tap advertises %.0f Hz but the device runs at %.0f Hz — using the device",
                            asbd.mSampleRate, deviceRate))
            asbd.mSampleRate = deviceRate
        }

        describedAs = "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, "
            + (asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float32" : "int")
            + (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? ", non-interleaved" : ", interleaved")

        var format: CMFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                          asbd: &asbd,
                                                          layoutSize: 0, layout: nil,
                                                          magicCookieSize: 0, magicCookie: nil,
                                                          extensions: nil,
                                                          formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else {
            throw Failure(stage: "CMAudioFormatDescriptionCreate", status: formatStatus)
        }
        formatDescription = format

        try startIOProc()
        accepting = true
        state = .attached(processes: trackedProcesses.count)
        onStateChange?(state)
    }

    private func aggregateNominalSampleRate() -> Float64? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float64>.size)
        var rate: Float64 = 0
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    private func makeTapDescription(_ mode: AudioMode) throws -> CATapDescription {
        let description: CATapDescription
        switch mode {
        case .processes(let bundleIDs):
            let (found, missing) = AudioProcesses.resolve(bundleIDs: bundleIDs)
            if found.isEmpty {
                let candidates = AudioProcesses.knownBundleIDs()
                    .filter { !$0.hasPrefix("com.apple.") }
                Log.raw("\nnothing matched \(bundleIDs.joined(separator: ", ")). "
                        + "Core Audio can currently see:\n")
                for c in candidates { Log.raw("    \(c)") }
                Log.raw("")
                throw Failure(stage: "no running audio process matched \(bundleIDs.joined(separator: ", "))",
                              status: noErr)
            }
            if !missing.isEmpty {
                Log.warn("not producing audio yet, so not in the tap: \(missing.joined(separator: ", "))")
            }
            description = CATapDescription(stereoMixdownOfProcesses: found)
            trackedProcesses = Set(found)

        case .globalExcludingSelf:
            // Exclude ourselves so the marker "tink" never lands in the clip.
            let (mine, _) = AudioProcesses.resolve(bundleIDs: [Bundle.main.bundleIdentifier ?? ""])
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: mine)
            trackedProcesses = []   // a global tap does not track anyone
        }

        description.name = "Observance Spike"
        description.isPrivate = true          // don't appear as a device to other apps
        description.muteBehavior = .unmuted   // keep playing through the speakers

        // macOS 26. Re-attaches a tapped process when it quits and comes back —
        // but it saves processes BY BUNDLE ID, and EVE's client reports none.
        // So this covers Discord and nothing else, and v1 still needs its own
        // relaunch watcher for the game itself.
        if #available(macOS 26.0, *) {
            description.isProcessRestoreEnabled = true
        }
        return description
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format)
        guard status == noErr, format.mSampleRate > 0 else {
            throw Failure(stage: "read kAudioTapPropertyFormat", status: status)
        }
        return format
    }

    private func makeAggregateDevice(tapUID: String) throws {
        guard let outputUID = AudioProcesses.defaultOutputDeviceUID() else {
            throw Failure(stage: "resolve default output device", status: noErr)
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Observance Spike Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID
            ]]
        ]
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            throw Failure(stage: "AudioHardwareCreateAggregateDevice", status: status)
        }
    }

    private func startIOProc() throws {
        var status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inputData, inputTime, _, _ in
            self?.handle(inputData, inputTime)
        }
        guard status == noErr, ioProcID != nil else {
            throw Failure(stage: "AudioDeviceCreateIOProcIDWithBlock", status: status)
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw Failure(stage: "AudioDeviceStart", status: status)
        }
    }

    // MARK: - Relaunch

    /// EVE's client reports no bundle ID, so `processRestoreEnabled` — which
    /// saves tapped processes by bundle ID — cannot bring it back. It covers
    /// Discord and nothing else. Quitting to character select would otherwise
    /// drop the game's audio for the rest of the session, silently: the tap
    /// keeps delivering, it just stops carrying EVE.
    ///
    /// So we watch the audio process list ourselves and rebuild when the set we
    /// actually matched changes.
    private func watchProcessList() {
        // A global tap follows the machine, not a process. Nothing to watch.
        guard case .processes = mode else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // The process list churns constantly — every helper that opens an
            // output stream moves it. Coalesce, then compare what we care about.
            self.pendingReconcile?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reconcile() }
            self.pendingReconcile = work
            self.control.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, block)
        if status == noErr {
            listener = block
        } else {
            Log.warn("could not watch the audio process list (OSStatus \(status)) — "
                     + "EVE relaunching will drop its audio until you restart")
        }
    }

    private func reconcile() {
        guard case .processes(let tokens) = mode else { return }
        let (found, _) = AudioProcesses.resolve(bundleIDs: tokens)
        let current = Set(found)
        guard current != trackedProcesses else { return }

        let before = trackedProcesses
        detach()

        if current.isEmpty {
            state = .waitingForProcesses
            onStateChange?(state)
            Log.warn("tapped process gone — waiting for \(tokens.joined(separator: ", ")) to return")
            trackedProcesses = []
            return
        }

        let previousRate = asbd.mSampleRate
        do {
            try attach()
            if asbd.mSampleRate != previousRate && previousRate > 0 {
                Log.warn(String(format: "stream format changed on reattach (%.0f → %.0f Hz) — "
                                + "dropping buffered audio", previousRate, asbd.mSampleRate))
                onFormatChange?()
            }
            Log.good(before.isEmpty
                     ? "audio reattached — \(current.count) process(es) back"
                     : "audio process set changed — tap rebuilt on \(current.count) process(es)")
        } catch {
            state = .failed(error.localizedDescription)
            onStateChange?(state)
            Log.fail("could not reattach the tap: \(error.localizedDescription)")
        }
    }

    /// Tear down the tap but keep the listener, so a rebuild is still possible.
    private func detach() {
        accepting = false
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Delivery

    private func handle(_ inputData: UnsafePointer<AudioBufferList>,
                        _ inputTime: UnsafePointer<AudioTimeStamp>) {
        guard accepting, let formatDescription else { return }
        let list = inputData.pointee
        guard list.mNumberBuffers > 0 else { return }

        let firstBuffer = list.mBuffers
        let bytesPerFrame = max(asbd.mBytesPerFrame, 1)
        let frames = Int(firstBuffer.mDataByteSize / bytesPerFrame)
        guard frames > 0 else { return }

        // Presentation time on the same clock ScreenCaptureKit stamps video with.
        let stamp = inputTime.pointee
        let pts: CMTime = (stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0)
            ? CMClockMakeHostTimeFromSystemUnits(stamp.mHostTime)
            : CMClockGetTime(CMClockGetHostTimeClock())

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        var status = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                          dataBuffer: nil, dataReady: false,
                                          makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: formatDescription,
                                          sampleCount: frames,
                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                          sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return }

        status = CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer,
                                                               blockBufferAllocator: kCFAllocatorDefault,
                                                               blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                               flags: 0,
                                                               bufferList: inputData)
        guard status == noErr else { return }

        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let scalars = interleaved ? frames * Int(asbd.mChannelsPerFrame) : frames
        let rms = Self.rms(of: firstBuffer, scalars: scalars)
        if firstHostTime == 0 { firstHostTime = stamp.mHostTime }
        lastHostTime = stamp.mHostTime
        framesDelivered &+= UInt64(frames)
        buffersSeen &+= 1
        peakRMS = max(peakRMS, rms)
        onSample?(sampleBuffer, rms)
    }

    /// TCC denial is silent — every call returns noErr and the buffers are
    /// zeros. Measuring level is the only way to know the tap is really live.
    private static func rms(of buffer: AudioBuffer, scalars: Int) -> Float {
        guard let raw = buffer.mData, scalars > 0 else { return 0 }
        let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let n = min(scalars, capacity)
        guard n > 0 else { return 0 }
        let samples = raw.assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        return (sum / Float(n)).squareRoot()
    }

    // MARK: - Teardown

    func stop() {
        pendingReconcile?.cancel()
        if let listener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, control, listener)
            self.listener = nil
        }
        detach()
    }
}
