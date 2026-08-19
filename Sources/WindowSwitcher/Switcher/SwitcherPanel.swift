import AppKit
import SwiftUI

/// Hosting view that accepts the first click even while the panel isn't
/// key, so after the user interacts with another app a card still activates
/// with a single click instead of needing a focus-restoring click first.
final class SwitcherHostingView: NSHostingView<SwitcherView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, non-activating panel: becomes key (so it receives keyboard)
/// without activating this app — the previously active app keeps the menu
/// bar. It floats above all windows (.popUpMenu level) and stays visible
/// when it loses key status; only an explicit pick or dismissal removes it.
final class SwitcherPanel: NSPanel {
    /// Fired when the panel loses key status (e.g. the user clicked into
    /// another app). Used to DISARM release-to-activate, never to dismiss.
    var onResignKey: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // Empty regions the SwiftUI content doesn't claim can drag the
        // panel; the top grip strip is the guaranteed drag zone.
        isMovableByWindowBackground = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    // Borderless windows refuse key status by default; without this,
    // makeKeyAndOrderFront silently fails to deliver any keyboard events.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
