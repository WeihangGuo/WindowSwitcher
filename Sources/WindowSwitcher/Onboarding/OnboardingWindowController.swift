import AppKit
import SwiftUI

final class OnboardingModel: ObservableObject {
    @Published var trusted = AX.isTrusted
}

/// First-launch Accessibility permission flow. Polls only while the window
/// is visible; grant is detected live (no app restart needed).
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model = OnboardingModel()
    var onGranted: (() -> Void)?

    private var window: NSWindow?
    private var pollTimer: Timer?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to WindowSwitcher"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        refresh()
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    /// Called by the poll timer and by the TCC distributed notification.
    func refresh() {
        let trusted = AX.isTrusted
        if trusted != model.trusted {
            model.trusted = trusted
        }
        if trusted {
            stopPolling()
            onGranted?()
        }
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to WindowSwitcher")
                        .font(.title2.weight(.semibold))
                    Text("A window-level Command-Tab for your Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("WindowSwitcher needs the macOS Accessibility permission to list your open windows, read their titles, and bring the one you choose to the front. It requests nothing else, captures no screenshots, and never leaves your Mac.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open System Settings → Privacy & Security → Accessibility.")
                step(2, "Enable WindowSwitcher in the list (add it with + if missing).")
                step(3, "That's it — no restart needed. This window updates by itself.")
            }

            Button("Open Accessibility Settings") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            }
            .keyboardShortcut(.defaultAction)

            HStack(spacing: 8) {
                Circle()
                    .fill(model.trusted ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                Text(model.trusted
                     ? "Permission granted — press ⌥⇥ anytime."
                     : "Permission not granted yet.")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.top, 2)

            if !model.trusted {
                Text("Already enabled but still not detected? That happens after the app is rebuilt or updated — remove WindowSwitcher from the Accessibility list with the − button, then add it back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(26)
        .frame(width: 480)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
