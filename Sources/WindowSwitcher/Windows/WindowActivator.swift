import AppKit
import ApplicationServices

/// Brings a window to the foreground. Order matters:
/// unminimize → raise → activate. Activating first would let AppKit raise
/// the app's most-recent window on the CURRENT Space before our raise lands
/// (flicker, or a wrong-Space switch). A verify-and-re-raise pass afterwards
/// covers apps where activation steals focus back.
enum WindowActivator {
    /// Close a window by pressing its close button via AX (the only public
    /// way to close another app's window). Reports success on main so the
    /// caller can update UI optimistically; the store hears about the actual
    /// destruction through its destroyed-notification.
    static func close(_ window: WindowInfo, completion: @escaping (Bool) -> Void) {
        WindowStore.axQueue.async {
            let pressed: Bool
            if let button = window.element.element(kAXCloseButtonAttribute) {
                pressed = button.perform(kAXPressAction) == .success
            } else {
                pressed = false // no close button (some windows can't close)
            }
            DispatchQueue.main.async {
                completion(pressed)
            }
        }
    }

    /// Main-thread confined. A newer activation cancels the previous
    /// pending verify so a stale re-raise can't yank focus back.
    private static var pendingVerify: DispatchWorkItem?

    static func activate(_ window: WindowInfo, store: WindowStore) {
        WindowStore.axQueue.async {
            var dead = false
            if window.isMinimized {
                let error = window.element.set(kAXMinimizedAttribute, kCFBooleanFalse)
                dead = error == .invalidUIElement
            }
            window.element.set(kAXMainAttribute, kCFBooleanTrue)
            let raiseError = window.element.perform(kAXRaiseAction)
            dead = dead || raiseError == .invalidUIElement

            DispatchQueue.main.async {
                guard let app = NSRunningApplication(processIdentifier: window.pid) else {
                    store.evictInvalidWindow(window)
                    return
                }
                // Deprecated on 14+, but the cooperative replacement can be
                // refused when called from a background LSUIElement app.
                app.activate(options: [.activateIgnoringOtherApps])

                if dead {
                    // Stale cache entry: degrade to "app comes forward" and repair.
                    store.evictInvalidWindow(window)
                    return
                }
                store.noteActivated(window)

                // Verify the right window ended up focused; if not, escalate
                // to the SkyLight fallback (cooperative activation on 14+
                // can silently refuse background apps), then re-raise.
                pendingVerify?.cancel()
                let verify = DispatchWorkItem {
                    let appElement = AXUIElement.application(pid: window.pid)
                    let focused = appElement.element(kAXFocusedWindowAttribute)
                    let appIsFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
                    if appIsFront, let focused, CFEqual(focused, window.element) {
                        return
                    }
                    if !appIsFront, let cgID = window.cgWindowID, SkyLight.isAvailable {
                        SkyLight.focusWindow(pid: window.pid, windowID: cgID)
                    }
                    window.element.set(kAXMainAttribute, kCFBooleanTrue)
                    window.element.perform(kAXRaiseAction)
                }
                pendingVerify = verify
                WindowStore.axQueue.asyncAfter(deadline: .now() + 0.15, execute: verify)
            }
        }
    }
}
