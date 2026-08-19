import AppKit
import Combine

/// An app the user pinned to the front of the switcher. The name is stored
/// too so the row still renders when the app isn't running.
struct PinnedApp: Codable, Equatable, Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// UserDefaults-backed settings, applied immediately on change.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let shortcut = "shortcut"
        static let columnOverride = "columnOverride" // 0 = automatic
        static let releaseToActivate = "releaseToActivate"
        static let pinnedApps = "pinnedApps"
    }

    /// The global shortcut that opens the switcher.
    @Published var shortcut: Shortcut {
        didSet { persistShortcut() }
    }

    /// Manual column count override; nil means automatic layout.
    @Published var columnOverride: Int? {
        didSet {
            UserDefaults.standard.set(columnOverride ?? 0, forKey: Keys.columnOverride)
        }
    }

    /// Off (default): the switcher stays open after the shortcut — pick a
    /// window or dismiss explicitly. On: releasing the shortcut's modifier
    /// switches immediately, like ⌘⇥.
    @Published var releaseToActivate: Bool {
        didSet {
            UserDefaults.standard.set(releaseToActivate, forKey: Keys.releaseToActivate)
        }
    }

    /// Apps that always appear first in the switcher, kept alphabetical
    /// (consistent with the grid's stable ordering).
    @Published var pinnedApps: [PinnedApp] {
        didSet {
            if let data = try? JSONEncoder().encode(pinnedApps) {
                UserDefaults.standard.set(data, forKey: Keys.pinnedApps)
            }
        }
    }

    func pin(bundleID: String, name: String) {
        guard !pinnedApps.contains(where: { $0.bundleID == bundleID }) else { return }
        pinnedApps.append(PinnedApp(bundleID: bundleID, name: name))
        pinnedApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func unpin(bundleID: String) {
        pinnedApps.removeAll { $0.bundleID == bundleID }
    }

    // Transient (not persisted): the recorder is capturing keys, so the live
    // hotkey must be unregistered or pressing the current shortcut would open
    // the switcher mid-recording.
    @Published var isRecordingShortcut = false
    /// Transient: the last registration attempt was refused by the system.
    @Published var shortcutRegistrationFailed = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.shortcut),
           let decoded = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = decoded
        } else {
            shortcut = .defaultShortcut
        }
        let storedColumns = UserDefaults.standard.integer(forKey: Keys.columnOverride)
        columnOverride = storedColumns > 0 ? storedColumns : nil
        releaseToActivate = UserDefaults.standard.bool(forKey: Keys.releaseToActivate)
        if let data = UserDefaults.standard.data(forKey: Keys.pinnedApps),
           let decoded = try? JSONDecoder().decode([PinnedApp].self, from: data) {
            pinnedApps = decoded
        } else {
            pinnedApps = []
        }
    }

    private func persistShortcut() {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: Keys.shortcut)
        }
    }

    func restoreDefaultShortcut() {
        shortcut = .defaultShortcut
    }
}
