import Foundation
import AppKit
import Carbon.HIToolbox

/// What the office remembers between watches.
///
/// Precedence is explicit-beats-stored: a value passed on the command line wins
/// for that run and is not written back. Otherwise a flag would silently become
/// a permanent preference, and you would never be able to try something once.
enum Settings {

    private static let store = UserDefaults.standard

    private enum Key {
        static let length = "replayLengthSeconds"
        static let capGB = "memoryCapGB"
        static let outputPath = "clipsDirectory"
        static let codec = "videoCodec"
        static let scale = "captureScale"
        static let fps = "frameRate"
        static let audioMode = "audioMode"          // "game" | "all" | "custom"
        static let audioNames = "audioProcessNames"
        static let hotKeyCode = "recordHotKeyCode"
        static let hotKeyMods = "recordHotKeyModifiers"
        static let hotKeyLabel = "recordHotKeyLabel"
    }

    static func registerDefaults() {
        store.register(defaults: [
            Key.length: 300.0,
            Key.capGB: 8.0,
            Key.codec: "hevc",
            Key.scale: 1.0,
            Key.fps: 60,
            Key.audioMode: "game",
            Key.audioNames: ["EVE.app", "com.hnc.Discord"],
            Key.hotKeyCode: Int(kVK_ANSI_S),
            Key.hotKeyMods: Int(optionKey | cmdKey),
            Key.hotKeyLabel: "⌥⌘S"
        ])
    }

    static var length: Double {
        get { store.double(forKey: Key.length) }
        set { store.set(max(10, min(1800, newValue)), forKey: Key.length) }
    }

    static var capGB: Double {
        get { store.double(forKey: Key.capGB) }
        set { store.set(max(0.5, min(24, newValue)), forKey: Key.capGB) }
    }

    static var outputDirectory: URL {
        get {
            if let path = store.string(forKey: Key.outputPath), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/VIGIL", isDirectory: true)
        }
        set { store.set(newValue.path, forKey: Key.outputPath) }
    }

    static var codec: String {
        get { store.string(forKey: Key.codec) ?? "hevc" }
        set { store.set(newValue == "h264" ? "h264" : "hevc", forKey: Key.codec) }
    }

    static var scale: Double {
        get { let v = store.double(forKey: Key.scale); return v > 0 ? v : 1.0 }
        set { store.set(max(0.25, min(1.0, newValue)), forKey: Key.scale) }
    }

    static var fps: Int32 {
        get { let v = store.integer(forKey: Key.fps); return v > 0 ? Int32(v) : 60 }
        set { store.set(Int(max(15, min(120, newValue))), forKey: Key.fps) }
    }

    static var audio: AudioMode {
        get {
            switch store.string(forKey: Key.audioMode) {
            case "all": return .globalExcludingSelf
            case "custom":
                let names = store.stringArray(forKey: Key.audioNames) ?? []
                return names.isEmpty ? .processes(["EVE.app"]) : .processes(names)
            default: return .processes(["EVE.app"])
            }
        }
    }

    /// Stored separately from `audio` so the picker can show which preset is on
    /// without having to infer it from a list of strings.
    static var audioPreset: String {
        get { store.string(forKey: Key.audioMode) ?? "game" }
        set { store.set(newValue, forKey: Key.audioMode) }
    }

    static var audioNames: [String] {
        get { store.stringArray(forKey: Key.audioNames) ?? ["EVE.app", "com.hnc.Discord"] }
        set { store.set(newValue, forKey: Key.audioNames) }
    }

    struct HotKey {
        var keyCode: UInt32
        var modifiers: UInt32
        var label: String
    }

    static var recordHotKey: HotKey {
        get {
            HotKey(keyCode: UInt32(store.integer(forKey: Key.hotKeyCode)),
                   modifiers: UInt32(store.integer(forKey: Key.hotKeyMods)),
                   label: store.string(forKey: Key.hotKeyLabel) ?? "⌥⌘S")
        }
        set {
            store.set(Int(newValue.keyCode), forKey: Key.hotKeyCode)
            store.set(Int(newValue.modifiers), forKey: Key.hotKeyMods)
            store.set(newValue.label, forKey: Key.hotKeyLabel)
        }
    }

    // MARK: - Chord description

    /// Carbon modifier mask from an NSEvent's flags.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: Int = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.shift) { mask |= shiftKey }
        return UInt32(mask)
    }

    static func label(modifiers: UInt32, key: String) -> String {
        var out = ""
        let mask = Int(modifiers)
        if mask & controlKey != 0 { out += "⌃" }
        if mask & optionKey != 0 { out += "⌥" }
        if mask & shiftKey != 0 { out += "⇧" }
        if mask & cmdKey != 0 { out += "⌘" }
        return out + key.uppercased()
    }

    /// A chord with no modifier would fire while you are typing in local.
    static func isUsable(modifiers: UInt32) -> Bool {
        Int(modifiers) & (cmdKey | optionKey | controlKey) != 0
    }
}
