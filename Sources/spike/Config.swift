import Foundation
import AVFoundation

enum AudioMode {
    /// Mix down only these bundle IDs. `initStereoMixdownOfProcesses:`
    case processes([String])
    /// Everything the machine plays, minus ourselves.
    /// `initStereoGlobalTapButExcludeProcesses:`
    case globalExcludingSelf
}

struct Config {
    var scale: Double = 1.0          // 1.0 = native backing resolution
    var fps: Int32 = 60
    var codec: AVVideoCodecType = .hevc
    var bitrate: Int? = nil          // nil = derive from pixel rate
    var audio: AudioMode = .processes(["EVE.app"])
    var length: Double = 300      // seconds retained in the ring
    var capGB: Double = 8         // hard memory ceiling regardless of length
    var selfTest = false         // --selftest: exercise ring -> clip -> file
    var listOnly = false         // --list: dump the audio process list
    var checkOnly = false        // --check: prove the tap alone, no video
    var outputDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/observance-spike", isDirectory: true)

    /// Bits per pixel per frame. Deliberately generous — this footage is
    /// source material for an editor, not a final upload.
    var bitsPerPixel: Double { codec == .hevc ? 0.08 : 0.15 }

    static func parse(_ argv: [String]) -> Config {
        var c = Config()
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            func next() -> String? { i += 1; return i < argv.count ? argv[i] : nil }
            switch arg {
            case "--scale":
                if let v = next(), let d = Double(v) { c.scale = max(0.25, min(1.0, d)) }
            case "--fps":
                if let v = next(), let n = Int32(v) { c.fps = max(15, min(120, n)) }
            case "--codec":
                if let v = next() { c.codec = (v.lowercased() == "h264") ? .h264 : .hevc }
            case "--bitrate":
                if let v = next(), let n = Int(v) { c.bitrate = n * 1_000_000 }
            case "--audio":
                // --audio all
                // --audio game
                // --audio com.ccpgames.eveonline,com.hnc.Discord
                if let v = next() {
                    switch v.lowercased() {
                    case "all":  c.audio = .globalExcludingSelf
                    case "game": c.audio = .processes(["EVE.app"])
                    default:
                        let ids = v.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }.filter { !$0.isEmpty }
                        if !ids.isEmpty { c.audio = .processes(ids) }
                    }
                }
            case "--out":
                if let v = next() { c.outputDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
            case "--length":
                if let v = next(), let d = Double(v) { c.length = max(10, min(1800, d)) }
            case "--cap":
                if let v = next(), let d = Double(v) { c.capGB = max(0.5, min(24, d)) }
            case "--selftest":
                c.selfTest = true
            case "--list":
                c.listOnly = true
            case "--check":
                c.checkOnly = true
            case "--help", "-h":
                print(Config.usage)
                exit(0)
            default:
                break
            }
            i += 1
        }
        return c
    }

    static let usage = """
    observance spike — does ScreenCaptureKit + a Core Audio process tap survive a fleet fight?

      --length <10-1800>   seconds of replay held in memory (default 300)
      --cap <GB>           hard memory ceiling for the ring (default 8)
      --scale <0.25-1.0>   capture size vs native backing resolution (default 1.0)
      --fps <15-120>       target frame rate (default 60)
      --codec hevc|h264    default hevc; h264 if your editor chokes on HEVC
      --bitrate <Mbps>     override the derived bitrate
      --audio <mode>       game | all | comma-separated process names
                           A name matches a bundle ID (exact or as a prefix),
                           an executable name, or a substring of the executable
                           path. EVE reports no bundle ID, so "game" means the
                           path fragment EVE.app.
                           default: game
      --out <dir>          default ~/Movies/observance-spike
      --list               print every process Core Audio can see, and whether
                           it is currently producing output. Start here when
                           --audio <bundle ids> says nothing matched.
      --selftest           fill the ring, save a clip, verify the file, exit.
                           No key press needed.
      --check              run the audio tap alone for 5 s and report signal
                           level, then exit. Use this to prove the System Audio
                           Recording grant before blaming anything else.

    hotkeys (Option-Command, and they work under fullscreen EVE):
      ⌥⌘S   start a clip — it opens with everything in the buffer and keeps
            recording live. Press again to stop and save it.
      ⌥⌘Q   quit
    """
}
