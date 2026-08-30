import Foundation
import CoreAudio
import Darwin

/// Enumerating the audio-process list is how the real app's picker should work:
/// never hardcode bundle IDs, ask Core Audio what is actually making noise.
enum AudioProcesses {

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func bundleID(of object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString = "" as CFString
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard err == noErr else { return nil }
        let s = value as String
        return s.isEmpty ? nil : s
    }

    static func pid(of object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = 0
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value > 0 ? value : nil
    }

    /// Core Audio reports no bundle ID for some processes — EVE's client among
    /// them. The executable name off the running-application list is the only
    /// way to identify those.
    static func executablePath(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func executableName(forPID pid: pid_t) -> String? {
        executablePath(forPID: pid).map { ($0 as NSString).lastPathComponent }
    }

    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningOutput)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// Resolve bundle IDs to live audio process objects.
    ///
    /// Matching is by prefix, because Electron apps — EVE's launcher, Discord,
    /// Chrome — never play audio from their main bundle. The sound comes out of
    /// `com.hnc.Discord.helper`, so asking for `com.hnc.Discord` has to catch
    /// the whole family or nobody would ever guess the right string.
    static func resolve(bundleIDs wanted: [String]) -> (found: [AudioObjectID], missing: [String]) {
        var found: [AudioObjectID] = []
        var matched = Set<String>()
        for object in all() {
            let bid = bundleID(of: object)
            let path = pid(of: object).flatMap { executablePath(forPID: $0) }
            for want in wanted where matches(want, bundleID: bid, path: path) {
                found.append(object)
                matched.insert(want)
                break
            }
        }
        return (found, wanted.filter { !matched.contains($0) })
    }

    /// Three ways to name a process, because one is never enough:
    ///   · bundle ID, exact or as a prefix — Electron apps play through
    ///     `com.hnc.Discord.helper`, never `com.hnc.Discord`
    ///   · executable name — EVE's client runs as `exefile`
    ///   · a substring of the executable path — EVE reports NO bundle ID at
    ///     all, so `EVE.app` is the only stable handle on it
    static func matches(_ token: String, bundleID bid: String?, path: String?) -> Bool {
        if let bid, bid == token || bid.hasPrefix(token + ".") { return true }
        guard let path else { return false }
        let name = (path as NSString).lastPathComponent
        if name.caseInsensitiveCompare(token) == .orderedSame { return true }
        return path.range(of: token, options: .caseInsensitive) != nil
    }

    /// Every bundle ID Core Audio can see, for error messages that actually help.
    static func knownBundleIDs() -> [String] {
        let names: [String] = all().compactMap { object in
            let bid = bundleID(of: object)
            let exe = pid(of: object).flatMap { executableName(forPID: $0) }
            switch (bid, exe) {
            case let (b?, e?): return b.hasPrefix("com.apple.") ? nil : "\(e)  (\(b))"
            case let (b?, nil): return b.hasPrefix("com.apple.") ? nil : b
            case let (nil, e?): return "\(e)  (no bundle id)"
            default: return nil
            }
        }
        return Array(Set(names)).sorted { $0.lowercased() < $1.lowercased() }
    }

    /// For the preflight report — what is audible right now.
    static func currentlyPlaying() -> [String] {
        all().compactMap { id in
            guard isRunningOutput(id), let bid = bundleID(of: id) else { return nil }
            return bid
        }.sorted()
    }

    static func defaultOutputDeviceUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var device = AudioObjectID(kAudioObjectUnknown)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device) == noErr else { return nil }

        var uidAddr = address(kAudioDevicePropertyDeviceUID)
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString = "" as CFString
        let err = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, $0)
        }
        guard err == noErr else { return nil }
        return uid as String
    }
}
