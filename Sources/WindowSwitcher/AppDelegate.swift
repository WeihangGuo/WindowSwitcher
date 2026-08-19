import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private let store = WindowStore()
    private let hotkeys = HotkeyManager()

    private var switcher: SwitcherController?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?

    private var cancellables = Set<AnyCancellable>()
    private var coreStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = StatusItemController()
        statusItem.onOpenSwitcher = { [weak self] in self?.openSwitcherSticky() }
        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }
        statusItem.onGrantAccess = { [weak self] in self?.showOnboarding() }
        self.statusItem = statusItem

        hotkeys.onForward = { [weak self] in self?.hotkeyPressed(forward: true) }
        hotkeys.onBackward = { [weak self] in self?.hotkeyPressed(forward: false) }
        hotkeys.onReleased = { [weak self] in self?.switcher?.hotkeyReleased() }
        applyShortcut()

        // Settings apply immediately.
        settings.$shortcut
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyShortcut() }
            .store(in: &cancellables)
        settings.$isRecordingShortcut
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                guard let self else { return }
                if recording {
                    self.hotkeys.unregister()
                } else {
                    self.applyShortcut()
                }
            }
            .store(in: &cancellables)

        // Fires on any Accessibility TCC change; the DB write can lag the
        // notification slightly, hence the delay before re-checking.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.trustMayHaveChanged()
            }
        }

        // Debug hook: `distributed-notify dev.window-manager.WindowSwitcher.debugDump`
        // makes the app reconcile and write its live window store to
        // /tmp/windowswitcher-dump.txt (local file, diagnostic use).
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("dev.window-manager.WindowSwitcher.debugDump"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.writeDebugDump()
        }

        if AX.isTrusted {
            startCore()
        } else {
            AX.promptForTrustIfNeeded()
            showOnboarding()
        }
    }

    private func writeDebugDump() {
        var header = "trusted: \(AX.isTrusted) coreStarted: \(coreStarted)\n"
        guard coreStarted else {
            try? header.write(toFile: "/tmp/windowswitcher-dump.txt", atomically: true, encoding: .utf8)
            return
        }
        header += store.debugSummary
        store.reconcile { [weak self] groups in
            header += self?.store.lastReconcileDiag ?? ""
            for group in groups {
                header += "\(group.appName) [pid \(group.id)]\n"
                for window in group.windows {
                    header += "  - '\(window.title)' min:\(window.isMinimized) fs:\(window.isFullscreen) cg:\(window.cgWindowID ?? 0)\n"
                }
            }
            try? header.write(toFile: "/tmp/windowswitcher-dump.txt", atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Hotkey

    private func applyShortcut() {
        let registered = hotkeys.register(settings.shortcut)
        settings.shortcutRegistrationFailed = !registered
    }

    private func hotkeyPressed(forward: Bool) {
        // A visible session must always receive the hotkey — it's the
        // documented toggle-close — even if AX trust vanished after it
        // opened (revoked mid-session, rebuilt binary).
        if let switcher, switcher.isSessionVisible {
            switcher.handleHotkey(forward: forward)
            return
        }
        // Trust can silently vanish (e.g. the binary was rebuilt): guide the
        // user instead of showing a half-dead panel.
        guard AX.isTrusted else {
            showOnboarding()
            return
        }
        if !coreStarted { startCore() }
        switcher?.handleHotkey(forward: forward)
    }

    // MARK: - Core

    private func startCore() {
        guard !coreStarted else { return }
        coreStarted = true
        store.start()
        let controller = SwitcherController(store: store, settings: settings)
        switcher = controller
        // Pay the SwiftUI cold-render cost now, not on the first hotkey.
        DispatchQueue.main.async {
            controller.prewarm()
        }
        // Warm-up reconcile: brute-force discovery of invisible/other-Space
        // windows normally runs at palette-open; doing it once shortly after
        // launch means the FIRST open already sees the full window set (and
        // computes the right column count). Delayed so app watches register.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.store.reconcile { _ in }
        }
    }

    private func trustMayHaveChanged() {
        onboarding?.refresh()
        if AX.isTrusted, !coreStarted {
            startCore()
        }
    }

    // MARK: - Windows

    private func openSwitcherSticky() {
        guard AX.isTrusted else {
            showOnboarding()
            return
        }
        if !coreStarted { startCore() }
        switcher?.showSticky()
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }

    private func showOnboarding() {
        if onboarding == nil {
            let onboarding = OnboardingWindowController()
            onboarding.onGranted = { [weak self] in
                self?.startCore()
            }
            self.onboarding = onboarding
        }
        onboarding?.show()
    }
}
