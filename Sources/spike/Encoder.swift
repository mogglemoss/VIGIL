import Foundation
import VideoToolbox
import CoreMedia
import AVFoundation

/// VTCompressionSession, replacing AVAssetWriter now that frames have to land
/// in a ring rather than a file. Same hardware encoder; the difference is that
/// we get the encoded CMSampleBuffer in our hands.
final class Encoder {

    struct Failure: LocalizedError {
        let stage: String, status: OSStatus
        var errorDescription: String? { "\(stage) failed (OSStatus \(status))" }
    }

    private var session: VTCompressionSession?
    private(set) var width: Int32 = 0
    private(set) var height: Int32 = 0

    /// Called on the encoder's own callback queue with each encoded frame.
    var onEncoded: ((CMSampleBuffer) -> Void)?

    func start(width: Int, height: Int, fps: Int32, codec: AVVideoCodecType, bitrate: Int) throws {
        stop()
        self.width = Int32(width); self.height = Int32(height)

        var session: VTCompressionSession?
        let codecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        var status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: Int32(width), height: Int32(height),
                                                codecType: codecType,
                                                encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw Failure(stage: "VTCompressionSessionCreate", status: status)
        }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // No B-frames: reordering costs latency and makes a ring trim ambiguous
        // about which frames a keyframe actually depends on.
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // 1-second GOP. This is the whole reason a clip can be saved without
        // re-encoding: every second there is a frame we can legally start from.
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1.0 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int(fps) as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, Int(fps) as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        if codec == .h264 {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        }

        status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else {
            throw Failure(stage: "VTCompressionSessionPrepareToEncodeFrames", status: status)
        }
    }

    func encode(_ pixelBuffer: CVImageBuffer, pts: CMTime, duration: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: pixelBuffer,
                                        presentationTimeStamp: pts,
                                        duration: duration,
                                        frameProperties: nil,
                                        infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
            self?.onEncoded?(sampleBuffer)
        }
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    /// A frame with no NotSync attachment is an IDR — a legal place to start a
    /// clip.
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }
}
