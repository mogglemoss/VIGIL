import Foundation
import Carbon.HIToolbox
import AppKit

/// Carbon RegisterEventHotKey, deliberately — not a CGEventTap.
///
/// RegisterEventHotKey fires while a fullscreen game holds focus and needs no
/// Accessibility or Input Monitoring grant. A CGEventTap needs Input Monitoring
/// and the system can disable it out from under you.
final class Hotkeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var refs: [EventHotKeyRef?] = []

    static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installEventHandlerIfNeeded()
        handlers[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x4F425356), id: id)  // 'OBSV'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return false }
        refs.append(ref)
        return true
    }

    private static func installEventHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            Hotkeys.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

}
