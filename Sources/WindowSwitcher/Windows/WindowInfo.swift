import AppKit
import ApplicationServices

/// Stable identity for a window across refreshes. Prefers the CGWindowID
/// (via SPI); falls back to the AXUIElement token hash for the few toolkits
/// where the SPI returns nothing.
struct WindowID: Hashable {
    let pid: pid_t
    let key: UInt64
}

struct WindowInfo: Identifiable {
    let id: WindowID
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    /// nil for the rare windows whose CGWindowID could not be resolved.
    let cgWindowID: CGWindowID?

    var title: String
    var isMinimized: Bool
    var isFullscreen: Bool
    /// Monotonic focus stamp; higher = focused more recently. 0 = never seen focused.
    var focusStamp: UInt64

    var displayTitle: String {
        title.isEmpty ? "Untitled" : title
    }
}

/// One application's windows (display order: by title).
struct AppWindowGroup: Identifiable {
    let id: pid_t
    let appName: String
    /// Stable identity across relaunches; drives the pinned-apps feature.
    let bundleID: String?
    var windows: [WindowInfo]
}
