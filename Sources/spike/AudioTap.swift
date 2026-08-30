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
    private var formatDescription: CMFormatDescription?
    private(set) var asbd = AudioStreamBasicDescription()
    private(set) var describedAs = ""

    /// Set once the first buffer arrives, so the caller can tell "not started"
    /// from "started but silent".
    private(set) var buffersSeen: UInt64 = 0
    private(set) var peakRMS: Float = 0

    private let queue = DispatchQueue(label: "app.observance.spike.tap", qos: .userInitiated)
    private var onSample: ((CMSampleBuffer, Float) -> Void)?

    // MARK: - Setup

    func start(mode: AudioMode, onSample: @escaping (CMSampleBuffer, Float) -> Void) throws {
        self.onSample = onSample

        let description = try makeTapDescription(mode)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw Failure(stage: "AudioHardwareCreateProcessTap", status: status)
        }

        asbd = try readTapFormat()
        describedAs = "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, "
            + (asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float32" : "int")
            + (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? ", non-interleaved" : ", interleaved")

        var format: CMFormatDescription?
        status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                asbd: &asbd,
                                                layoutSize: 0, layout: nil,
                                                magicCookieSize: 0, magicCookie: nil,
                                                extensions: nil,
                                                formatDescriptionOut: &format)
        guard status == noErr, let format else {
            throw Failure(stage: "CMAudioFormatDescriptionCreate", status: status)
        }
        formatDescription = format

        try makeAggregateDevice(tapUID: description.uuid.uuidString)
        try startIOProc()
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

        case .globalExcludingSelf:
            // Exclude ourselves so the marker "tink" never lands in the clip.
            let (mine, _) = AudioProcesses.resolve(bundleIDs: [Bundle.main.bundleIdentifier ?? ""])
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: mine)
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

    // MARK: - Delivery

    private func handle(_ inputData: UnsafePointer<AudioBufferList>,
                        _ inputTime: UnsafePointer<AudioTimeStamp>) {
        guard let formatDescription else { return }
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
}
