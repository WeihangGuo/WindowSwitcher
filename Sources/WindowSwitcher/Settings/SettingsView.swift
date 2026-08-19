import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Open switcher") {
                    ShortcutRecorderView()
                }
                if settings.shortcutRegistrationFailed {
                    Text("This shortcut couldn't be registered — it may already be in use. Try a different one.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Button("Restore Default (⌥⇥)") {
                    settings.restoreDefaultShortcut()
                }
                .disabled(settings.shortcut == .defaultShortcut)
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("Click the shortcut, then press a new key combination (it needs ⌘, ⌥, or ⌃; ⎋ cancels). Press the shortcut again to cycle through windows; add ⇧ to cycle backward.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.pinnedApps.isEmpty {
                    Text("No pinned apps")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.pinnedApps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: Self.icon(forBundleID: app.bundleID))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        Button {
                            settings.unpin(bundleID: app.bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Unpin \(app.name)")
                    }
                }
                Menu("Add App…") {
                    let candidates = Self.runningAppCandidates(excluding: Set(settings.pinnedApps.map(\.bundleID)))
                    if candidates.isEmpty {
                        Text("All running apps are pinned")
                    }
                    ForEach(candidates, id: \.bundleID) { candidate in
                        Button(candidate.name) {
                            settings.pin(bundleID: candidate.bundleID, name: candidate.name)
                        }
                    }
                }
            } header: {
                Text("Pinned Apps")
            } footer: {
                Text("Pinned apps always appear before the others in the switcher.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Switch on modifier release", isOn: $settings.releaseToActivate)
            } header: {
                Text("Behavior")
            } footer: {
                Text("Off: the switcher stays open — cycle with the shortcut or arrows, press ↩ or click to switch, ⎋ to close. On: releasing the shortcut's modifier switches immediately, like ⌘⇥.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Columns", selection: columnBinding) {
                    Text("Automatic").tag(0)
                    ForEach(1..<9, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
            } header: {
                Text("Grid Layout")
            } footer: {
                Text("Automatic picks a column count from the display size. Settings apply immediately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Grouped forms are scroll-view-backed and have NO intrinsic height:
        // without an explicit one, the hosting window collapses to a bare
        // title bar. The form scrolls internally if content outgrows this.
        .frame(width: 480, height: 600)
    }

    private var columnBinding: Binding<Int> {
        Binding(
            get: { settings.columnOverride ?? 0 },
            set: { settings.columnOverride = $0 == 0 ? nil : $0 }
        )
    }

    private static func runningAppCandidates(excluding pinned: Set<String>) -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !pinned.contains(bundleID) else { return nil }
                return (bundleID, app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func icon(forBundleID bundleID: String) -> NSImage {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = running.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

// MARK: - Shortcut recorder

/// Click to record; the next key press (with its modifiers) becomes the
/// shortcut. Escape cancels. The live hotkey is unregistered while recording
/// (via SettingsStore.isRecordingShortcut).
struct ShortcutRecorderView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var recorder = ShortcutRecorderModel()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                recorder.isRecording ? recorder.cancel() : recorder.begin()
            } label: {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 130)
            }
            if let message = recorder.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { recorder.cancel() }
    }

    private var label: String {
        if recorder.isRecording {
            return recorder.liveModifiers.isEmpty ? "Type shortcut…" : recorder.liveModifiers
        }
        return settings.shortcut.displayString
    }
}

final class ShortcutRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var liveModifiers = ""
    @Published var message: String?

    private var monitor: Any?
    private var willCloseObserver: NSObjectProtocol?

    func begin() {
        guard !isRecording else { return }
        isRecording = true
        message = nil
        liveModifiers = ""
        SettingsStore.shared.isRecordingShortcut = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.liveModifiers = Self.symbols(for: event.modifierFlags)
                return nil
            }
            self.handleKeyDown(event)
            return nil
        }
        // onDisappear never fires when a retained (isReleasedWhenClosed =
        // false) window is closed — without this, the monitor would leak and
        // the global hotkey would stay unregistered indefinitely.
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cancel()
        }
    }

    func cancel() {
        guard isRecording else { return }
        stop()
    }

    private func handleKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mods = Shortcut.carbonModifiers(from: flags)

        if event.keyCode == UInt32(kVK_Escape), mods == 0 {
            stop()
            return
        }
        // Release-to-activate is meaningless without a held (non-Shift) modifier.
        guard mods & ~UInt32(shiftKey) != 0 else {
            message = "Include ⌘, ⌥, or ⌃ in the shortcut."
            return
        }
        // The Dock's switcher consumes ⌘⇥ before global hot keys ever fire.
        if event.keyCode == UInt32(kVK_Tab), mods == UInt32(cmdKey) {
            message = "⌘⇥ is reserved by macOS. Try ⌥⇥ instead."
            return
        }
        SettingsStore.shared.shortcut = Shortcut(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
        stop()
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let willCloseObserver {
            NotificationCenter.default.removeObserver(willCloseObserver)
            self.willCloseObserver = nil
        }
        isRecording = false
        liveModifiers = ""
        SettingsStore.shared.isRecordingShortcut = false
    }

    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }
}
