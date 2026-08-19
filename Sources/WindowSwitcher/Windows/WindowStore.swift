import AppKit
import ApplicationServices

/// Event-driven cache of every eligible window on the system.
///
/// Why a cache instead of enumerate-on-open: kAXWindowsAttribute only returns
/// windows on the CURRENT Space (plus minimized windows and windows of hidden
/// apps). Windows on other Spaces — including native-fullscreen windows,
/// which live on their own Space — are invisible to fresh AX enumeration.
/// A cached AXUIElement, however, stays valid and raisable across Space
/// changes. So the cache IS the mechanism for cross-Space coverage:
/// - enumerate on launch, on app launch, and on every Space change
///   (each visited Space back-fills the cache),
/// - reconcile non-destructively: absence from kAXWindowsAttribute never
///   evicts; only a destroyed notification, app termination, or absence
///   from the all-Spaces CGWindowList does,
/// - cold-start gaps (windows on never-visited Spaces) are back-filled by
///   brute-force remote-token resolution when the SPI is available.
///
/// Threading: state lives on the main thread. All AX IPC — reads AND
/// observer registrations — runs on a serial background queue; AXObserver
/// callbacks fire on the main run loop, do a cheap lookup, and bounce any
/// AX work to the background queue.
final class WindowStore {
    static let axQueue = DispatchQueue(label: "WindowStore.ax", qos: .userInitiated)

    // Main-thread state.
    private(set) var windows: [WindowID: WindowInfo] = [:] {
        didSet { scheduleChangeNotification() }
    }
    private(set) var lastFocusedWindowID: WindowID?

    /// Fired (debounced, on main) whenever the window set changes, so a
    /// visible palette stays live without any polling of its own.
    var onWindowsChanged: (() -> Void)?
    private var changeNotificationPending = false

    private func scheduleChangeNotification() {
        guard !changeNotificationPending else { return }
        changeNotificationPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.changeNotificationPending = false
            self.onWindowsChanged?()
        }
    }

    private var appElements: [pid_t: AXUIElement] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var observerBoxes: [pid_t: ObserverBox] = [:]
    private var appNames: [pid_t: String] = [:]
    private var appBundleIDs: [pid_t: String] = [:]
    private var appStamps: [pid_t: UInt64] = [:]
    /// Apps whose observer registration is in flight on axQueue.
    private var pendingWatch: Set<pid_t> = []

    /// Genuine focus stamps start far above the launch-time z-order seed
    /// range (1...windowCount), so a seed that lands late can never outrank
    /// a window the user actually focused in the meantime.
    private var focusCounter: UInt64 = 1 << 32

    /// Apps hidden with ⌘H. Their windows vanish from CGWindowList (like
    /// minimized ones) but must stay listed and switchable — exempt them
    /// from the liveness eviction.
    private var hiddenPids: Set<pid_t> = []

    /// Consecutive failed fetches per app; quarantined apps are skipped in
    /// reconcile until their backoff expires so one hung app cannot stall
    /// every open.
    private var fetchFailures: [pid_t: Int] = [:]
    private var quarantinedUntil: [pid_t: Date] = [:]

    /// CGWindowIDs we already tried (and failed) to resolve by brute force,
    /// so each open doesn't repeat the scan. Cleared on Space change.
    private var attemptedBruteForce: [pid_t: Set<CGWindowID>] = [:]

    /// Windows the user closed from the palette. Hide-on-close apps keep
    /// the window alive (merely ordered out), and invisible-window discovery
    /// would resurface it immediately — exclude such windows from listing
    /// until the app itself shows them again (onscreen or focused).
    private var userClosedIDs: Set<WindowID> = []

    /// Windows evicted by destroyed-notifications or dead-element repair.
    /// An in-flight axQueue snapshot may still contain them, so the insert
    /// paths must not resurrect them. The TTL comfortably exceeds any
    /// snapshot-to-apply latency.
    private var tombstones: [WindowID: Date] = [:]
    private static let tombstoneTTL: TimeInterval = 10

    /// Pending title-changed debounce work, per window.
    private var titleDebounce: [WindowID: DispatchWorkItem] = [:]

    /// Diagnostics from the most recent reconcile, for the debug dump.
    private(set) var lastReconcileDiag = ""

    var debugSummary: String {
        let watched = appNames.map { "\($0.key):\($0.value)\(observers[$0.key] == nil ? "(watchless)" : "")" }
            .sorted().joined(separator: ", ")
        return "watched: \(watched)\npendingWatch: \(pendingWatch.sorted())\nhidden: \(hiddenPids.sorted())\n"
    }

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Refcon for AX observer callbacks; retained per-app in `observerBoxes`.
    final class ObserverBox {
        let pid: pid_t
        unowned let store: WindowStore
        init(pid: pid_t, store: WindowStore) {
            self.pid = pid
            self.store = store
        }
    }

    // MARK: - Lifecycle

    func start() {
        AX.setGlobalMessagingTimeout(0.5)

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.watchAppIfEligible(app)
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unwatchApp(pid: app.processIdentifier)
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appDidActivate(app.processIdentifier)
        })
        // Each visited Space back-fills windows AX couldn't see before.
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.attemptedBruteForce.removeAll()
            for pid in self.appElements.keys {
                self.refreshApp(pid: pid)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.hiddenPids.insert(app.processIdentifier)
            // Visibility changed: previously unresolvable windows may
            // resolve now — let the next reconcile retry them.
            self?.attemptedBruteForce.removeValue(forKey: app.processIdentifier)
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.hiddenPids.remove(app.processIdentifier)
            self?.attemptedBruteForce.removeValue(forKey: app.processIdentifier)
            self?.upgradeWatchIfNeeded(pid: app.processIdentifier)
            self?.refreshApp(pid: app.processIdentifier)
        })

        for app in NSWorkspace.shared.runningApplications {
            watchAppIfEligible(app)
            if app.isHidden {
                hiddenPids.insert(app.processIdentifier)
            }
        }
        seedInitialOrderFromZOrder()
    }

    // MARK: - App watching

    private func watchAppIfEligible(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ownPID,
              observers[pid] == nil, !pendingWatch.contains(pid) else { return }
        watchApp(
            pid: pid,
            name: app.localizedName ?? app.bundleIdentifier ?? "App",
            bundleID: app.bundleIdentifier,
            retryDelay: 0.25
        )
    }

    /// AX servers of freshly launched apps come up late (Java and Steam are
    /// the worst); retry with backoff up to ~16s before giving up.
    /// AXObserverCreate is process-local (kept on main); the registrations
    /// are synchronous IPC and run on axQueue.
    private func watchApp(pid: pid_t, name: String, bundleID: String?, retryDelay: TimeInterval) {
        guard observers[pid] == nil, !pendingWatch.contains(pid) else { return }

        var maybeObserver: AXObserver?
        guard AXObserverCreate(pid, WindowStore.axCallback, &maybeObserver) == .success,
              let observer = maybeObserver else {
            scheduleWatchRetry(pid: pid, name: name, bundleID: bundleID, retryDelay: retryDelay)
            return
        }
        pendingWatch.insert(pid)

        let appElement = AXUIElement.application(pid: pid)
        let box = ObserverBox(pid: pid, store: self)
        WindowStore.axQueue.async { [weak self] in
            // `box` is captured strongly, keeping the refcon alive.
            let refcon = Unmanaged.passUnretained(box).toOpaque()
            var errors: [AXError] = []
            for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                errors.append(AXObserverAddNotification(observer, appElement, notification as CFString, refcon))
            }
            let registered = errors.allSatisfy { $0 == .success || $0 == .notificationAlreadyRegistered }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingWatch.remove(pid)
                guard self.observers[pid] == nil else { return }
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
                if registered {
                    self.observers[pid] = observer
                    self.observerBoxes[pid] = box
                    self.appElements[pid] = appElement
                    self.appNames[pid] = name
                    self.appBundleIDs[pid] = bundleID
                    // Callbacks can only be delivered once the source is
                    // added, so no event races this registration.
                    CFRunLoopAddSource(
                        CFRunLoopGetMain(),
                        AXObserverGetRunLoopSource(observer),
                        .commonModes
                    )
                    IconCache.shared.prepare(pid: pid)
                    self.refreshApp(pid: pid)
                } else {
                    self.scheduleWatchRetry(pid: pid, name: name, bundleID: bundleID, retryDelay: retryDelay)
                }
            }
        }
    }

    private func scheduleWatchRetry(pid: pid_t, name: String, bundleID: String?, retryDelay: TimeInterval) {
        guard retryDelay < 16 else {
            // Observer registration keeps failing (hidden apps can refuse
            // it entirely). Adopt the app WITHOUT an observer so reconcile
            // fetch + brute force still cover it; upgraded to a full watch
            // when the app later activates or unhides.
            adoptWatchless(pid: pid, name: name, bundleID: bundleID)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self, self.observers[pid] == nil, !self.pendingWatch.contains(pid),
                  let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
            self.watchApp(pid: pid, name: name, bundleID: bundleID, retryDelay: retryDelay * 2)
        }
    }

    private func adoptWatchless(pid: pid_t, name: String, bundleID: String?) {
        guard observers[pid] == nil, appElements[pid] == nil,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        appElements[pid] = AXUIElement.application(pid: pid)
        appNames[pid] = name
        appBundleIDs[pid] = bundleID
        IconCache.shared.prepare(pid: pid)
        refreshApp(pid: pid)
    }

    /// Watchless apps get a real observer once they come back to life.
    private func upgradeWatchIfNeeded(pid: pid_t) {
        guard observers[pid] == nil, !pendingWatch.contains(pid),
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        appElements.removeValue(forKey: pid) // let watchApp rebuild cleanly
        watchAppIfEligible(app)
    }

    private func unwatchApp(pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observerBoxes.removeValue(forKey: pid)
        appElements.removeValue(forKey: pid)
        appNames.removeValue(forKey: pid)
        appBundleIDs.removeValue(forKey: pid)
        appStamps.removeValue(forKey: pid)
        fetchFailures.removeValue(forKey: pid)
        quarantinedUntil.removeValue(forKey: pid)
        attemptedBruteForce.removeValue(forKey: pid)
        hiddenPids.remove(pid)
        for id in windows.keys where id.pid == pid {
            windows.removeValue(forKey: id)
            titleDebounce.removeValue(forKey: id)?.cancel()
        }
        userClosedIDs = userClosedIDs.filter { $0.pid != pid }
        if lastFocusedWindowID?.pid == pid {
            lastFocusedWindowID = nil
        }
        IconCache.shared.evict(pid: pid)
    }

    /// Registers per-window notifications on axQueue (synchronous IPC). If
    /// the element is already dead (.invalidUIElement), the cache entry that
    /// was just inserted for it is removed again — otherwise it would be an
    /// unevictable ghost (no destroyed-notification will ever fire for it).
    private func watchWindowElement(_ element: AXUIElement, pid: pid_t, id: WindowID) {
        guard let observer = observers[pid], let box = observerBoxes[pid] else { return }
        WindowStore.axQueue.async { [weak self] in
            // `box` captured strongly: refcon stays valid for the calls.
            let refcon = Unmanaged.passUnretained(box).toOpaque()
            var dead = false
            for notification in [
                kAXUIElementDestroyedNotification,
                kAXWindowMiniaturizedNotification,
                kAXWindowDeminiaturizedNotification,
                kAXTitleChangedNotification,
            ] {
                if AXObserverAddNotification(observer, element, notification as CFString, refcon) == .invalidUIElement {
                    dead = true
                }
            }
            if dead {
                DispatchQueue.main.async {
                    self?.removeWindow(id: id)
                }
            }
        }
    }

    // MARK: - AX notifications (fire on the main run loop)

    private static let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let box = Unmanaged<WindowStore.ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
        box.store.handleAXNotification(notification as String, element: element, pid: box.pid)
    }

    private func handleAXNotification(_ notification: String, element: AXUIElement, pid: pid_t) {
        switch notification {
        case kAXWindowCreatedNotification:
            insertWindowElement(element, pid: pid, stampFocus: false)

        case kAXFocusedWindowChangedNotification:
            // Validate off-main: some apps deliver sheets/panels here.
            WindowStore.axQueue.async { [weak self] in
                let subrole = element.string(kAXSubroleAttribute)
                guard subrole == nil || subrole == kAXStandardWindowSubrole else { return }
                let key = WindowStore.identityKey(for: element)
                DispatchQueue.main.async {
                    guard let self else { return }
                    let id = WindowID(pid: pid, key: key)
                    if self.windows[id] != nil {
                        self.stampFocus(id)
                    } else {
                        // A window we missed (some apps never post windowCreated).
                        self.insertWindowElement(element, pid: pid, stampFocus: true)
                    }
                }
            }

        case kAXUIElementDestroyedNotification:
            removeWindowsMatching(element, pid: pid)

        case kAXWindowMiniaturizedNotification:
            updateWindowMatching(element, pid: pid) { $0.isMinimized = true }

        case kAXWindowDeminiaturizedNotification:
            updateWindowMatching(element, pid: pid) { $0.isMinimized = false }

        case kAXTitleChangedNotification:
            // Chatty in terminals/browsers; debounce per window.
            guard let id = findID(for: element, pid: pid) else { return }
            titleDebounce[id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                WindowStore.axQueue.async {
                    let title = element.string(kAXTitleAttribute) ?? ""
                    DispatchQueue.main.async {
                        self?.windows[id]?.title = title
                    }
                }
            }
            titleDebounce[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)

        default:
            break
        }
    }

    private func insertWindowElement(_ element: AXUIElement, pid: pid_t, stampFocus shouldStamp: Bool) {
        guard let appName = appNames[pid] else { return }
        WindowStore.axQueue.async { [weak self] in
            guard let info = WindowStore.buildWindowInfo(element, pid: pid, appName: appName) else { return }
            DispatchQueue.main.async {
                guard let self, self.observers[pid] != nil, !self.isTombstoned(info.id) else { return }
                let isNew = self.windows[info.id] == nil
                var merged = info
                merged.focusStamp = self.windows[info.id]?.focusStamp ?? 0
                self.migrateStaleHashEntry(for: &merged)
                self.windows[merged.id] = merged
                if isNew {
                    self.watchWindowElement(element, pid: pid, id: merged.id)
                }
                if shouldStamp {
                    self.stampFocus(merged.id)
                }
            }
        }
    }

    /// A window first cached under its CFHash fallback key can later be
    /// re-discovered with a resolved CGWindowID; drop the stale entry so the
    /// same window never appears twice.
    private func migrateStaleHashEntry(for info: inout WindowInfo) {
        guard info.cgWindowID != nil else { return }
        guard let staleID = windows.first(where: {
            $0.key.pid == info.pid && $0.value.cgWindowID == nil && CFEqual($0.value.element, info.element)
        })?.key else { return }
        info.focusStamp = max(info.focusStamp, windows[staleID]?.focusStamp ?? 0)
        windows.removeValue(forKey: staleID)
        titleDebounce.removeValue(forKey: staleID)?.cancel()
        if lastFocusedWindowID == staleID {
            lastFocusedWindowID = info.id
        }
    }

    /// Identity lookup that works for DEAD elements too: token equality
    /// (CFEqual) needs no IPC and keeps working after the window is gone.
    private func findID(for element: AXUIElement, pid: pid_t) -> WindowID? {
        windows.first { key, value in
            key.pid == pid && CFEqual(value.element, element)
        }?.key
    }

    private func removeWindow(id: WindowID) {
        windows.removeValue(forKey: id)
        titleDebounce.removeValue(forKey: id)?.cancel()
        userClosedIDs.remove(id)
        tombstone(id)
        if lastFocusedWindowID == id {
            lastFocusedWindowID = nil
        }
    }

    private func removeWindowsMatching(_ element: AXUIElement, pid: pid_t) {
        // Destroyed notifications fire for every element in some apps;
        // early-out via the identity lookup, no AX calls. Remove ALL
        // token-equal entries (a hash-keyed duplicate may coexist).
        let ids = windows.filter { $0.key.pid == pid && CFEqual($0.value.element, element) }.map(\.key)
        for id in ids {
            removeWindow(id: id)
        }
    }

    private func updateWindowMatching(_ element: AXUIElement, pid: pid_t, _ mutate: (inout WindowInfo) -> Void) {
        guard let id = findID(for: element, pid: pid) else { return }
        mutate(&windows[id]!)
    }

    // MARK: - Tombstones

    private func tombstone(_ id: WindowID) {
        let cutoff = Date().addingTimeInterval(-Self.tombstoneTTL)
        tombstones = tombstones.filter { $0.value > cutoff }
        tombstones[id] = Date()
    }

    private func isTombstoned(_ id: WindowID) -> Bool {
        guard let at = tombstones[id] else { return false }
        if Date().timeIntervalSince(at) > Self.tombstoneTTL {
            tombstones.removeValue(forKey: id)
            return false
        }
        return true
    }

    // MARK: - Focus / MRU

    private func appDidActivate(_ pid: pid_t) {
        guard pid != ownPID else { return }
        upgradeWatchIfNeeded(pid: pid)
        appStamps[pid] = nextStamp()
        // The app's own kAXFocusedWindowChanged normally follows and stamps
        // the window; a delayed read covers apps that never post it.
        // (Reading immediately races and returns the previous window.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let appElement = self.appElements[pid] else { return }
            WindowStore.axQueue.async { [weak self] in
                guard let focused = appElement.element(kAXFocusedWindowAttribute) else { return }
                let subrole = focused.string(kAXSubroleAttribute)
                guard subrole == nil || subrole == kAXStandardWindowSubrole else { return }
                let key = WindowStore.identityKey(for: focused)
                DispatchQueue.main.async {
                    guard let self else { return }
                    // The user may have moved on during the delay; stamping
                    // now would put a background app's window on top.
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    let id = WindowID(pid: pid, key: key)
                    if let existing = self.windows[id] {
                        if existing.focusStamp < (self.appStamps[pid] ?? 0) {
                            self.stampFocus(id)
                        }
                    } else {
                        self.insertWindowElement(focused, pid: pid, stampFocus: true)
                    }
                }
            }
        }
    }

    private func stampFocus(_ id: WindowID) {
        guard windows[id] != nil else { return }
        // A focused window is visibly alive again — clear any user-closed mark.
        userClosedIDs.remove(id)
        let stamp = nextStamp()
        windows[id]?.focusStamp = stamp
        appStamps[id.pid] = max(appStamps[id.pid] ?? 0, stamp)
        lastFocusedWindowID = id
    }

    private func nextStamp() -> UInt64 {
        focusCounter += 1
        return focusCounter
    }

    func noteActivated(_ window: WindowInfo) {
        windows[window.id]?.isMinimized = false
        stampFocus(window.id)
    }

    /// The user closed this window from the palette: keep it out of the
    /// listing even if the app only ordered it out instead of destroying it.
    func noteUserClosed(_ id: WindowID) {
        userClosedIDs.insert(id)
    }

    /// A raise/unminimize hit a dead element: drop it and repair.
    func evictInvalidWindow(_ window: WindowInfo) {
        removeWindow(id: window.id)
        refreshApp(pid: window.pid)
    }

    /// Approximate initial MRU order from the current on-screen z-order,
    /// so the first invocation is sensible before any focus events arrive.
    /// Seed stamps (1...N) sit strictly below genuine stamps (> 2^32).
    private func seedInitialOrderFromZOrder() {
        WindowStore.axQueue.async { [weak self] in
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] ?? []
            // Front-to-back order.
            let orderedIDs: [(CGWindowID, pid_t)] = list.compactMap { entry in
                guard let number = entry[kCGWindowNumber as String] as? UInt32,
                      let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                      (entry[kCGWindowLayer as String] as? Int) == 0 else { return nil }
                return (number, pid)
            }
            // Enqueued after the per-app fetches on this serial queue, so the
            // main-queue inserts land before these stamps do.
            DispatchQueue.main.async {
                guard let self else { return }
                var stamp = UInt64(orderedIDs.count) + 1
                for (windowNumber, pid) in orderedIDs {
                    let id = WindowID(pid: pid, key: UInt64(windowNumber))
                    stamp -= 1
                    if self.windows[id] != nil, self.windows[id]?.focusStamp == 0 {
                        self.windows[id]?.focusStamp = stamp
                        self.appStamps[pid] = max(self.appStamps[pid] ?? 0, stamp)
                        if self.lastFocusedWindowID == nil {
                            self.lastFocusedWindowID = id
                        }
                    }
                }
                if let front = NSWorkspace.shared.frontmostApplication {
                    self.appStamps[front.processIdentifier] = self.nextStamp()
                }
            }
        }
    }

    // MARK: - Enumeration

    static func identityKey(for element: AXUIElement) -> UInt64 {
        if let cgID = element.cgWindowID {
            return UInt64(cgID)
        }
        return UInt64(bitPattern: Int64(CFHash(element)))
    }

    /// nil when the app could not be queried at all (keep the cache rather
    /// than wiping it).
    private static func fetchWindows(appElement: AXUIElement, pid: pid_t, appName: String) -> [WindowInfo]? {
        guard let elements = appElement.elements(kAXWindowsAttribute) else { return nil }
        return elements.compactMap { buildWindowInfo($0, pid: pid, appName: appName) }
    }

    private static func buildWindowInfo(_ element: AXUIElement, pid: pid_t, appName: String, allowDialogSubrole: Bool = false) -> WindowInfo? {
        let role: String?
        let subrole: String?
        let title: String?
        let minimized: Bool
        let fullscreen: Bool
        // One Mach round trip for all attributes...
        if let values = element.multiValues([
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute, "AXFullScreen",
        ]) {
            role = values[0] as? String
            subrole = values[1] as? String
            title = values[2] as? String
            minimized = values[3] as? Bool ?? false
            fullscreen = values[4] as? Bool ?? false
        } else {
            // ...but batched reads can fail wholesale on brute-forced
            // (remote-token) elements where individual reads succeed.
            guard let individualRole = element.string(kAXRoleAttribute) else { return nil }
            role = individualRole
            subrole = element.string(kAXSubroleAttribute)
            title = element.string(kAXTitleAttribute)
            minimized = element.bool(kAXMinimizedAttribute) ?? false
            fullscreen = element.bool("AXFullScreen") ?? false
        }
        guard role == kAXWindowRole else { return nil }
        // Standard windows only: excludes floating panels, tooltips, popovers.
        // Accept a missing subrole (some non-native toolkits omit it).
        // Invisible windows (⌘H-hidden, ✕-closed-but-alive) misreport their
        // subrole as AXDialog, so the brute-force discovery path relaxes
        // the filter to dialogs — but only TITLED ones: untitled dialogs
        // found this way are ghost sheets/panels (verified empirically).
        if let subrole, subrole != kAXStandardWindowSubrole {
            guard allowDialogSubrole, subrole == kAXDialogSubrole,
                  !(title ?? "").isEmpty else { return nil }
        }
        let cgID = element.cgWindowID
        let key = cgID.map { UInt64($0) } ?? UInt64(bitPattern: Int64(CFHash(element)))
        return WindowInfo(
            id: WindowID(pid: pid, key: key),
            element: element,
            pid: pid,
            appName: appName,
            cgWindowID: cgID,
            title: title ?? "",
            isMinimized: minimized,
            isFullscreen: fullscreen,
            focusStamp: 0
        )
    }

    private func refreshApp(pid: pid_t) {
        guard let appElement = appElements[pid], let appName = appNames[pid] else { return }
        WindowStore.axQueue.async { [weak self] in
            let fetched = WindowStore.fetchWindows(appElement: appElement, pid: pid, appName: appName)
            DispatchQueue.main.async {
                guard let self else { return }
                if let fetched {
                    self.noteFetchSucceeded(pid: pid)
                    self.applyFetched(fetched, pid: pid)
                } else {
                    self.noteFetchFailed(pid: pid)
                }
            }
        }
    }

    /// Non-destructive merge: adds and updates only. A window absent from
    /// kAXWindowsAttribute may simply be on another Space — never evict here.
    private func applyFetched(_ fetched: [WindowInfo], pid: pid_t) {
        guard observers[pid] != nil else { return }
        for var info in fetched {
            if let existing = windows[info.id] {
                info.focusStamp = existing.focusStamp
                windows[info.id] = info
            } else if !isTombstoned(info.id) {
                migrateStaleHashEntry(for: &info)
                windows[info.id] = info
                watchWindowElement(info.element, pid: pid, id: info.id)
            }
        }
    }

    // MARK: - Quarantine (one hung app must not stall every reconcile)

    private func noteFetchSucceeded(pid: pid_t) {
        fetchFailures[pid] = 0
        quarantinedUntil.removeValue(forKey: pid)
    }

    private func noteFetchFailed(pid: pid_t) {
        let failures = (fetchFailures[pid] ?? 0) + 1
        fetchFailures[pid] = failures
        if failures >= 3 {
            let backoff = min(60.0, pow(2.0, Double(failures - 3)) * 5.0)
            quarantinedUntil[pid] = Date().addingTimeInterval(backoff)
        }
    }

    private func isQuarantined(_ pid: pid_t) -> Bool {
        guard let until = quarantinedUntil[pid] else { return false }
        if until < Date() {
            quarantinedUntil.removeValue(forKey: pid)
            return false
        }
        return true
    }

    // MARK: - Reconcile

    /// Called when the switcher opens (after painting from cache).
    /// 1. Re-fetch each responsive app's AX windows (adds/updates only).
    /// 2. Use the all-Spaces CGWindowList as liveness ground truth: evict
    ///    cached windows whose CGWindowID no longer exists.
    /// 3. Brute-force-resolve listed windows we have no element for
    ///    (cold-start windows on other Spaces), where the SPI exists —
    ///    but ONLY for apps whose fetch succeeded in this same pass; the
    ///    fetch doubles as a bounded responsiveness probe, so a hung app
    ///    can never wedge the serial queue behind a 1500-probe scan.
    func reconcile(_ completion: @escaping ([AppWindowGroup]) -> Void) {
        let apps = appElements
            .filter { !isQuarantined($0.key) }
            .map { (pid: $0.key, element: $0.value, name: appNames[$0.key] ?? "App") }
        let watchedPids = Set(appElements.keys)
        let knownIDsByPid: [pid_t: Set<CGWindowID>] = windows.values.reduce(into: [:]) { acc, info in
            if let cgID = info.cgWindowID {
                acc[info.pid, default: []].insert(cgID)
            }
        }
        let alreadyAttempted = attemptedBruteForce
        let hiddenSnapshot = hiddenPids

        WindowStore.axQueue.async { [weak self] in
            var diag = ""
            var fetchResults: [(pid_t, [WindowInfo]?)] = []
            var responsivePids = Set<pid_t>()
            for app in apps {
                let fetched = WindowStore.fetchWindows(appElement: app.element, pid: app.pid, appName: app.name)
                if fetched != nil { responsivePids.insert(app.pid) }
                fetchResults.append((app.pid, fetched))
                diag += "fetch \(app.name)[\(app.pid)]: \(fetched.map { "\($0.count)" } ?? "nil")\n"
            }

            // All-Spaces ground truth. Layer 0 = standard windows. Minimized
            // windows may be absent here, so they are never evicted by this.
            let allList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            var liveIDs = Set<CGWindowID>()
            var onscreenIDs = Set<CGWindowID>()
            var liveByPid: [pid_t: Set<CGWindowID>] = [:]
            for entry in allList {
                guard let number = entry[kCGWindowNumber as String] as? UInt32,
                      let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                      (entry[kCGWindowLayer as String] as? Int) == 0,
                      watchedPids.contains(pid) else { continue }
                liveIDs.insert(number)
                liveByPid[pid, default: []].insert(number)
                if (entry[kCGWindowIsOnscreen as String] as? Bool) == true {
                    onscreenIDs.insert(number)
                }
            }

            // Resolve listed windows we hold no element for (other-Space,
            // cold start). Skipped apps' IDs are NOT marked attempted, so
            // they get resolved on the first reconcile after recovery.
            var resolved: [(pid_t, [WindowInfo])] = []
            var attempted: [pid_t: Set<CGWindowID>] = [:]
            // Hidden (⌘H) apps refuse kAXWindowsAttribute enumeration
            // entirely, so a failed fetch there does NOT mean unresponsive —
            // brute force is the ONLY discovery path for apps hidden before
            // we launched (verified empirically). The wall-clock budget in
            // resolveElements bounds the damage if such an app is truly hung.
            if RemoteToken.isAvailable {
                for app in apps where responsivePids.contains(app.pid) || hiddenSnapshot.contains(app.pid) {
                    let missing = (liveByPid[app.pid] ?? [])
                        .subtracting(knownIDsByPid[app.pid] ?? [])
                        .subtracting(alreadyAttempted[app.pid] ?? [])
                    guard !missing.isEmpty else { continue }
                    attempted[app.pid] = missing
                    let elements = RemoteToken.resolveElements(pid: app.pid, targetWindowIDs: missing)
                    let infos = elements.values.compactMap {
                        WindowStore.buildWindowInfo($0, pid: app.pid, appName: app.name, allowDialogSubrole: true)
                    }
                    diag += "bruteforce \(app.name)[\(app.pid)]: targets=\(missing.count) resolvedWindows=\(elements.count) eligible=\(infos.count)\n"
                    if !infos.isEmpty {
                        resolved.append((app.pid, infos))
                    }
                }
            }

            // Windows the apps' own AX enumeration still reports. A window
            // can be absent from the window server (red-✕ "closed" but only
            // ordered out — Telegram/WeChat-style) yet fully alive and
            // raisable; such windows must stay listed.
            let axListedIDs = Set(fetchResults.flatMap { $0.1 ?? [] }.map(\.id))

            DispatchQueue.main.async {
                guard let self else { return }
                self.lastReconcileDiag = diag
                for (pid, fetched) in fetchResults {
                    if let fetched {
                        self.noteFetchSucceeded(pid: pid)
                        self.applyFetched(fetched, pid: pid)
                    } else {
                        self.noteFetchFailed(pid: pid)
                    }
                }
                for (pid, infos) in resolved {
                    self.applyFetched(infos, pid: pid)
                }
                for (pid, ids) in attempted {
                    self.attemptedBruteForce[pid, default: []].formUnion(ids)
                }
                // A user-closed window that the app re-shows (Dock click)
                // is visibly alive again: bring it back to the listing.
                self.userClosedIDs = self.userClosedIDs.filter { id in
                    guard let cgID = self.windows[id]?.cgWindowID else { return false }
                    return !onscreenIDs.contains(cgID)
                }
                // Evict only windows that no longer exist ANYWHERE: absent
                // from the window server's all-Spaces list AND from their
                // app's AX enumeration. Minimized windows, ⌘H-hidden apps'
                // windows, and ✕-closed-but-alive (ordered-out) windows all
                // fail only one of the two checks and stay listed.
                for (id, info) in self.windows {
                    guard let cgID = info.cgWindowID,
                          !info.isMinimized,
                          !self.hiddenPids.contains(id.pid),
                          !liveIDs.contains(cgID),
                          !axListedIDs.contains(id) else { continue }
                    self.removeWindow(id: id)
                }
                completion(self.snapshotGroups())
            }
        }
    }

    // MARK: - Snapshot

    /// Display order is deliberately STABLE, not MRU: apps alphabetically,
    /// windows within an app by title. Spatial memory beats recency here
    /// (user decision). Focus stamps still exist — they power the
    /// quick-toggle initial selection and the current-window marker.
    func snapshotGroups() -> [AppWindowGroup] {
        var byApp: [pid_t: [WindowInfo]] = [:]
        for info in windows.values where !userClosedIDs.contains(info.id) {
            byApp[info.pid, default: []].append(info)
        }
        return byApp
            .map { pid, list -> AppWindowGroup in
                let sorted = list.sorted {
                    let order = $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle)
                    if order != .orderedSame { return order == .orderedAscending }
                    return $0.focusStamp > $1.focusStamp
                }
                return AppWindowGroup(
                    id: pid,
                    appName: appNames[pid] ?? sorted[0].appName,
                    bundleID: appBundleIDs[pid],
                    windows: sorted
                )
            }
            .sorted {
                let order = $0.appName.localizedCaseInsensitiveCompare($1.appName)
                if order != .orderedSame { return order == .orderedAscending }
                return $0.id < $1.id
            }
    }

    /// The most recently focused window other than the current one — the
    /// quick-toggle target the switcher preselects on open.
    func previousWindowID() -> WindowID? {
        windows.values
            .filter { $0.id != lastFocusedWindowID && $0.focusStamp > 0 }
            .max { $0.focusStamp < $1.focusStamp }?
            .id
    }
}
