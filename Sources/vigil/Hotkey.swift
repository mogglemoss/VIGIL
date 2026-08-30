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
    private static var refs: [UInt32: EventHotKeyRef] = [:]

    static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installEventHandlerIfNeeded()
        handlers[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x4F425356), id: id)  // 'OBSV'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    /// Swap a chord at runtime. If the new one is already spoken for, the old
    /// one is put back rather than leaving the pilot with no hotkey at all.
    static func rebind(id: UInt32, keyCode: UInt32, modifiers: UInt32,
                       fallbackKeyCode: UInt32, fallbackModifiers: UInt32) -> Bool {
        let action = handlers[id]
        unregister(id: id)
        if let action, register(id: id, keyCode: keyCode, modifiers: modifiers, action: action) {
            return true
        }
        if let action {
            _ = register(id: id, keyCode: fallbackKeyCode,
                         modifiers: fallbackModifiers, action: action)
        }
        return false
    }

    static func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
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
