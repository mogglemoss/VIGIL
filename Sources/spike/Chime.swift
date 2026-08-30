import AppKit

/// The office does not chime. It stamps.
///
/// Two cues, both the sound of paperwork being dealt with — dry, mechanical,
/// over before you have finished hearing them. Struck by
/// `Resources/strike-sounds.py`; no samples and no licences.
///
/// Neither ever reaches a clip: in `--audio all` the tap excludes this process,
/// and in per-process mode we were never in it.
enum Chime {
    case latch   // the record is opened — a drawer catching, 70 ms
    case stamp   // the record is filed — rubber on paper on desk, 150 ms

    private static var cache: [String: NSSound] = [:]

    private var resource: String {
        switch self {
        case .latch: return "latch"
        case .stamp: return "stamp"
        }
    }

    func play() {
        let name = resource
        DispatchQueue.main.async {
            if let cached = Self.cache[name] {
                cached.stop()          // re-strike rather than queue behind itself
                cached.play()
                return
            }
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
                  let sound = NSSound(contentsOf: url, byReference: false) else { return }
            Self.cache[name] = sound
            sound.play()
        }
    }
}
