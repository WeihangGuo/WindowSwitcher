import AppKit
import SwiftUI

/// Owns the switcher panel and the whole interaction session.
///
/// The panel is a persistent palette: it floats above every window,
/// survives losing focus, and even STAYS OPEN when the user activates a
/// window from it. It goes away only via the hotkey toggle, ⎋ while it has
/// keyboard focus, or closing its last window. Every exit path funnels
/// through the single `dismiss()` teardown so no monitor or timer leaks.
final class SwitcherController {
    private let store: WindowStore
    private let settings: SettingsStore
    private let panel: SwitcherPanel
    let model: SwitcherViewModel

    private var isVisible = false
    /// Modifiers whose release commits the selection (empty = sticky mode).
    private var armedModifiers: NSEvent.ModifierFlags = []

    /// Whether a switcher session is on screen (for callers that must route
    /// around other guards, e.g. the hotkey toggle when AX trust is lost).
    var isSessionVisible: Bool { isVisible }

    private var localKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var modifierPollTimer: Timer?
    private var holdRepeatTimer: Timer?
    private var memoryTimer: Timer?

    /// Where the user last dragged the panel (its center). Reused on the
    /// next open while it still fits the active screen; nil = center.
    private var draggedCenter: NSPoint?
    private var isProgrammaticMove = false

    init(store: WindowStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        self.model = SwitcherViewModel()
        self.panel = SwitcherPanel()

        let hosting = SwitcherHostingView(rootView: SwitcherView(model: model))
        panel.contentView = hosting

        model.onActivate = { [weak self] window in
            self?.commit(with: window)
        }
        model.onClose = { [weak self] window in
            self?.closeWindow(window)
        }
        // Losing key status while armed (user clicked into another app while
        // still holding the modifier) must disarm release-to-activate, or
        // the eventual release would steal focus from the window they chose.
        // The panel itself stays visible — this never dismisses.
        panel.onResignKey = { [weak self] in
            self?.disarm()
        }

        // The palette can stay open indefinitely; keep it fed with live
        // window changes (open/close/title/minimize) from the event stream.
        // merge() preserves visible order, so nothing jumps around.
        store.onWindowsChanged = { [weak self] in
            guard let self, self.isVisible else { return }
            self.model.merge(fresh: self.orderedGroups())
            if self.model.isEmpty {
                self.dismiss()
            }
        }

        // Remember user drags (didMove also fires for our own setFrame,
        // hence the programmatic-move flag).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, self.isVisible, !self.isProgrammaticMove else { return }
            self.draggedCenter = NSPoint(x: self.panel.frame.midX, y: self.panel.frame.midY)
        }
    }

    /// Force one offscreen render pass at launch so the first real show
    /// doesn't pay the SwiftUI/NSVisualEffectView cold-start cost.
    /// The guard matters: prewarm is scheduled async, so a hotkey-triggered
    /// show() can already be on screen by the time this runs — wiping the
    /// model and ordering the live panel out would tear down the session.
    func prewarm() {
        guard !isVisible else { return }
        model.load(groups: [], columnCount: 1, currentWindowID: nil)
        panel.setFrame(NSRect(x: -20000, y: -20000, width: 900, height: 500), display: false)
        panel.orderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderOut(nil)
    }

    // MARK: - Entry points

    /// Global shortcut pressed (forward or the Shift variant).
    /// Sticky mode (default): the shortcut TOGGLES the switcher — a re-press
    /// closes it and never moves the selection. In the opt-in
    /// release-to-activate mode, a re-press cycles, as ⌘⇥ users expect.
    func handleHotkey(forward: Bool) {
        if isVisible {
            if armedModifiers.isEmpty {
                dismiss()
            } else {
                forward ? model.selectNext() : model.selectPrevious()
                scheduleHoldRepeat(forward: forward)
            }
        } else {
            show(armed: settings.releaseToActivate)
            if isVisible, !armedModifiers.isEmpty {
                scheduleHoldRepeat(forward: forward)
            }
        }
    }

    /// Shortcut key released (modifiers may still be down): stop hold-cycling.
    func hotkeyReleased() {
        holdRepeatTimer?.invalidate()
        holdRepeatTimer = nil
    }

    /// Opened from the status-bar menu: no modifier is held, so the panel
    /// stays until Return / Escape / click.
    func showSticky() {
        guard !isVisible else { return }
        show(armed: false)
    }

    // MARK: - Session

    /// Pinned apps first (both halves stay alphabetical).
    private func orderedGroups() -> [AppWindowGroup] {
        let groups = store.snapshotGroups()
        let pinned = Set(settings.pinnedApps.map(\.bundleID))
        guard !pinned.isEmpty else { return groups }
        let isPinned: (AppWindowGroup) -> Bool = { group in
            group.bundleID.map(pinned.contains) ?? false
        }
        return groups.filter(isPinned) + groups.filter { !isPinned($0) }
    }

    private func show(armed: Bool) {
        guard !isVisible else { return }
        let groups = orderedGroups()
        guard let screen = targetScreen() else { return }
        let visible = screen.visibleFrame
        let pad = SwitcherLayout.panelPadding
        let maxContentWidth = visible.width * 0.75 - pad * 2
        let maxContentHeight = visible.height * 0.75 - pad * 2

        let columnCount = computeColumnCount(
            groups: groups,
            maxContentWidth: maxContentWidth,
            maxContentHeight: maxContentHeight
        )
        model.load(groups: groups, columnCount: columnCount, currentWindowID: store.lastFocusedWindowID)
        model.selectInitial(preferring: store.previousWindowID())

        // Size to content, capped at ~75% of the display's usable area.
        // Anchor on the user's dragged position when it's still on screen;
        // otherwise center. Clamp fully into the visible area either way.
        let content = model.contentSize
        let width = min(max(content.width, SwitcherLayout.columnWidth) + pad * 2, visible.width * 0.75)
        let height = min(max(content.height, 80) + pad * 2, visible.height * 0.75)
        var center = NSPoint(x: visible.midX, y: visible.midY)
        if let draggedCenter, visible.contains(draggedCenter) {
            center = draggedCenter
        }
        var frame = NSRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - height)

        isProgrammaticMove = true
        panel.setFrame(frame.integral, display: false)
        isProgrammaticMove = false
        isVisible = true
        panel.makeKeyAndOrderFront(nil)
        installMonitors()

        armedModifiers = armed ? settings.shortcut.eventModifiers.subtracting(.shift) : []
        if !armedModifiers.isEmpty {
            // Fast-tap race: the user may have released the modifier before
            // the panel/monitors came up — commit instantly (this is also
            // Command-Tab's quick-tap-switches-to-previous-window behavior).
            if currentModifierFlags().intersection(armedModifiers) != armedModifiers {
                commit()
                return
            }
            // This poll is the PRIMARY release detector, not a fallback:
            // flagsChanged events follow app ACTIVATION, not key-window
            // focus, so a never-activating app doesn't receive the
            // modifier-up (the local monitor stays silent), and global
            // keyboard monitors require Input Monitoring on modern macOS.
            // The session hardware state needs no permission at all.
            // Runs only while the panel is open; .common mode so it keeps
            // firing during event tracking (menus, scroll gestures).
            let poll = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.checkModifiers(self.currentModifierFlags())
            }
            RunLoop.main.add(poll, forMode: .common)
            modifierPollTimer = poll
        }

        // Panel is already on screen from cache; repair drift asynchronously.
        store.reconcile { [weak self] fresh in
            guard let self, self.isVisible else { return }
            self.model.merge(fresh: fresh)
        }

        // Live per-app RAM readout; sampled only while visible so idle
        // cost stays zero.
        refreshMemory()
        let memory = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshMemory()
        }
        RunLoop.main.add(memory, forMode: .common)
        memoryTimer = memory
    }

    private func refreshMemory() {
        let pids = Set(model.groups.map(\.id))
        guard !pids.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sample = MemorySampler.sample(appPids: pids)
            DispatchQueue.main.async {
                guard let self, self.isVisible else { return }
                self.model.memoryByApp = sample
            }
        }
    }

    /// Close a window without leaving the switcher (hover ✕ or ⌘W), so
    /// several can be closed in a row. The panel dismisses itself only when
    /// nothing is left.
    private func closeWindow(_ window: WindowInfo) {
        WindowActivator.close(window) { [weak self] success in
            guard let self, success else { return }
            // Hide-on-close apps only order the window out; without this
            // mark, invisible-window discovery would resurface the card
            // the user just closed.
            self.store.noteUserClosed(window.id)
            guard self.isVisible else { return }
            self.model.removeWindow(id: window.id)
            if self.model.isEmpty {
                self.dismiss()
            }
        }
    }

    /// Activate a window. Sticky sessions (the default) keep the palette
    /// open — only the hotkey toggle or ⎋ closes it. Release-to-activate
    /// sessions are momentary (⌘⇥ semantics) and dismiss on commit.
    private func commit(with window: WindowInfo? = nil) {
        let target = window ?? model.selectedWindow
        if !armedModifiers.isEmpty {
            dismiss()
        }
        if let target {
            WindowActivator.activate(target, store: store)
            if isVisible {
                model.markCurrent(target.id)
            }
        }
    }

    /// Convert an armed (release-to-activate) session into a sticky one.
    private func disarm() {
        guard isVisible, !armedModifiers.isEmpty else { return }
        armedModifiers = []
        modifierPollTimer?.invalidate()
        modifierPollTimer = nil
        holdRepeatTimer?.invalidate()
        holdRepeatTimer = nil
    }

    private func dismiss() {
        guard isVisible else { return }
        isVisible = false

        modifierPollTimer?.invalidate()
        modifierPollTimer = nil
        holdRepeatTimer?.invalidate()
        holdRepeatTimer = nil
        memoryTimer?.invalidate()
        memoryTimer = nil

        for monitor in [localKeyMonitor, localFlagsMonitor, globalFlagsMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        localKeyMonitor = nil
        localFlagsMonitor = nil
        globalFlagsMonitor = nil

        armedModifiers = []
        panel.orderOut(nil)
    }

    // MARK: - Event monitors

    private func installMonitors() {
        // Local keyDown: the panel is key, so all keyboard lands here.
        // Handled by keyCode — SwiftUI's focus system is unreliable in a
        // non-activating panel. Everything is consumed while open (returning
        // the event would just beep in a borderless window).
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.panel else { return event }
            self.handleKeyDown(event)
            return nil
        }
        // Local flagsChanged is load-bearing: global monitors never see
        // events delivered to our own (key) panel.
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.checkModifiers(event.modifierFlags)
            return event
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.checkModifiers(event.modifierFlags)
        }
        // Deliberately NO outside-click / app-activation / Space-change
        // dismissal: the panel is a persistent overlay. It rides along to
        // other Spaces (.canJoinAllSpaces) and stays above every window.
    }

    private func handleKeyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            dismiss()
        case 36, 76: // Return, keypad Enter
            commit()
        case 123:
            model.moveLeft()
        case 124:
            model.moveRight()
        case 125:
            model.moveDown()
        case 126:
            model.moveUp()
        case 48: // Tab fallback if hotkey registration ever failed
            event.modifierFlags.contains(.shift) ? model.selectPrevious() : model.selectNext()
        default:
            // ⌘W: close the selected window (layout-aware, not keycode 13).
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "w",
               let selected = model.selectedWindow {
                closeWindow(selected)
            }
        }
    }

    private func checkModifiers(_ flags: NSEvent.ModifierFlags) {
        guard isVisible, !armedModifiers.isEmpty else { return }
        let current = flags.intersection(.deviceIndependentFlagsMask)
        if current.intersection(armedModifiers) != armedModifiers {
            commit()
        }
    }

    /// Session-wide hardware modifier state from the window server.
    /// NSEvent.modifierFlags would reflect only OUR process's event stream,
    /// which goes stale the moment events stop being delivered to us.
    private func currentModifierFlags() -> NSEvent.ModifierFlags {
        let state = CGEventSource.flagsState(.combinedSessionState)
        var flags: NSEvent.ModifierFlags = []
        if state.contains(.maskCommand) { flags.insert(.command) }
        if state.contains(.maskAlternate) { flags.insert(.option) }
        if state.contains(.maskControl) { flags.insert(.control) }
        if state.contains(.maskShift) { flags.insert(.shift) }
        return flags
    }

    /// Hold-the-key-to-keep-cycling, like holding Tab in Command-Tab.
    /// Cancelled by hotkeyReleased() (Carbon key-up) and by dismiss().
    private func scheduleHoldRepeat(forward: Bool) {
        holdRepeatTimer?.invalidate()
        let delay = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let repeatTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, self.isVisible else { return }
                forward ? self.model.selectNext() : self.model.selectPrevious()
            }
            RunLoop.main.add(repeatTimer, forMode: .common)
            self.holdRepeatTimer = repeatTimer
        }
        RunLoop.main.add(delay, forMode: .common)
        holdRepeatTimer = delay
    }

    // MARK: - Layout

    /// The display currently being used: the one with the pointer.
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Fewest columns whose masonry fits the height budget (so the panel
    /// stays compact), bounded by what fits in the width budget. A manual
    /// override wins, clamped to the width budget.
    private func computeColumnCount(groups: [AppWindowGroup], maxContentWidth: CGFloat, maxContentHeight: CGFloat) -> Int {
        let maxByWidth = max(1, min(8, Int(
            (maxContentWidth + SwitcherLayout.columnSpacing)
                / (SwitcherLayout.columnWidth + SwitcherLayout.columnSpacing)
        )))
        if let override = settings.columnOverride {
            return max(1, min(override, maxByWidth))
        }
        let sizes = groups.map(\.windows.count)
        guard !sizes.isEmpty else { return 1 }
        var columns = 1
        while columns < maxByWidth,
              SwitcherLayout.masonryHeight(groupSizes: sizes, columns: columns) > maxContentHeight {
            columns += 1
        }
        return columns
    }
}
