import Foundation
import ServiceManagement

/// Standing at login, so the watch is already there when EVE starts.
///
/// SMAppService rather than a hand-written LaunchAgent plist: the system owns
/// the registration, it shows up in System Settings › General › Login Items
/// where a pilot can turn it off without knowing what a plist is, and it cannot
/// be left behind by an app that was dragged to the bin.
///
/// This is what makes "starts when EVE starts" true. VIGIL waits for the game's
/// window rather than launching alongside it, so being present at login and
/// idle is the whole mechanism.
enum LoginItem {

    enum State {
        case on
        case off
        case needsApproval      // registered, but the pilot has to allow it
        case unavailable(String)
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .notRegistered: return .off
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable("the bundle could not be found")
        @unknown default: return .unavailable("unknown status")
        }
    }

    /// Returns nil on success, or why it could not be done.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Registering an app that lives in a build directory works and then breaks
    /// the first time that directory is cleaned. Worth saying so rather than
    /// letting it fail silently months later.
    static var isInstalledProperly: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }
}
