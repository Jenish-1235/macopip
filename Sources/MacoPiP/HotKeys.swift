import Carbon.HIToolbox
import Foundation

/// Global hotkeys via Carbon. Unlike event taps, these need no Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKeyCenter.shared.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// `modifiers` uses Carbon masks (controlKey, optionKey, cmdKey, shiftKey).
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D50_4950), id: id) // 'MPIP'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
        } else {
            NSLog("MacoPiP: could not register hotkey %d (status %d)", keyCode, status)
        }
    }
}
