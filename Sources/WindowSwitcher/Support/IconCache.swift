import AppKit

/// Application icons, pre-rasterized once at a fixed point size on a
/// background queue so first paint of the switcher never triggers an
/// IconServices decode (product principle: icons decoded once and reused).
final class IconCache {
    static let shared = IconCache()

    private let queue = DispatchQueue(label: "IconCache", qos: .utility)
    // Main-thread reads.
    private var icons: [pid_t: NSImage] = [:]
    private let fallback = NSWorkspace.shared.icon(for: .applicationBundle)

    /// Rasterize and cache the app's icon ahead of time.
    func prepare(pid: pid_t) {
        queue.async { [weak self] in
            guard let self,
                  let source = NSRunningApplication(processIdentifier: pid)?.icon else { return }
            let rendered = Self.rasterize(source, pointSize: 64)
            DispatchQueue.main.async {
                self.icons[pid] = rendered
            }
        }
    }

    func icon(for pid: pid_t) -> NSImage {
        if let cached = icons[pid] { return cached }
        // Cache miss (app appeared between prepare and render): decode now
        // and keep it.
        let icon = NSRunningApplication(processIdentifier: pid)?.icon ?? fallback
        let rendered = Self.rasterize(icon, pointSize: 64)
        icons[pid] = rendered
        return rendered
    }

    func evict(pid: pid_t) {
        icons.removeValue(forKey: pid)
    }

    private static func rasterize(_ image: NSImage, pointSize: CGFloat) -> NSImage {
        var rect = CGRect(x: 0, y: 0, width: pointSize * 2, height: pointSize * 2)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return image
        }
        let result = NSImage(cgImage: cgImage, size: NSSize(width: pointSize, height: pointSize))
        return result
    }
}
