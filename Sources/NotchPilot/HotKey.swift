import Carbon.HIToolbox
import Foundation

/// System-wide shortcut via Carbon RegisterEventHotKey: needs no Accessibility or
/// Input Monitoring permission and never sits in the keyboard event path.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?

    init?(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E50_4C54), id: id) // 'NPLT'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                  GetEventDispatcherTarget(), 0, &ref) == noErr else { return nil }
        Self.handlers[id] = handler
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKey.handlers[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
