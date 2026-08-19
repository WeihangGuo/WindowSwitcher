import AppKit
import Carbon.HIToolbox

/// Registers the global shortcut via Carbon hot keys. These fire without any
/// event tap, cost nothing while idle, and swallow the key event so it never
/// reaches the frontmost app.
///
/// Hot key id 1 = cycle forward; id 2 = same key with Shift = cycle backward
/// (only registered when the user's shortcut does not itself include Shift).
final class HotkeyManager {
    var onForward: (() -> Void)?
    var onBackward: (() -> Void)?
    /// Fired on hot-key key-up (modifiers may still be held); used to stop
    /// hold-to-cycle repetition.
    var onReleased: (() -> Void)?

    private var forwardRef: EventHotKeyRef?
    private var backwardRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let signature: OSType = 0x5753_5752 // 'WSWR'

    func installHandler() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotkeyManager.signature else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    manager.onReleased?()
                } else if hotKeyID.id == 1 {
                    manager.onForward?()
                } else if hotKeyID.id == 2 {
                    manager.onBackward?()
                }
                return noErr
            },
            2, &specs,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    /// Returns false when the system refuses the registration (typically a
    /// conflict with another global shortcut).
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        installHandler()
        unregister()

        var forward: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(), 0, &forward
        )
        guard status == noErr, forward != nil else { return false }
        forwardRef = forward

        if !shortcut.includesShift {
            var backward: EventHotKeyRef?
            let backStatus = RegisterEventHotKey(
                shortcut.keyCode, shortcut.carbonModifiers | UInt32(shiftKey),
                EventHotKeyID(signature: Self.signature, id: 2),
                GetEventDispatcherTarget(), 0, &backward
            )
            if backStatus == noErr {
                backwardRef = backward
            }
        }
        return true
    }

    func unregister() {
        if let forwardRef {
            UnregisterEventHotKey(forwardRef)
            self.forwardRef = nil
        }
        if let backwardRef {
            UnregisterEventHotKey(backwardRef)
            self.backwardRef = nil
        }
    }
}
