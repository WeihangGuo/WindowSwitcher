import AppKit
import ApplicationServices

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrustIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Sets the process-global default AX messaging timeout. Per-element
    /// timeouts do NOT inherit from app elements, so this is the only way to
    /// bound every window-element read against unresponsive apps.
    static func setGlobalMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }
}

// MARK: - Private SPI (loaded via dlsym so a future removal degrades instead of crashing)

private func loadSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    dlsym(dlopen(nil, RTLD_LAZY), name)
}

/// _AXUIElementGetWindow: the only way to correlate an AXUIElement with a
/// CGWindowID. Stable since 10.10; shipped by AltTab, yabai, et al.
private let axGetWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
    guard let sym = loadSymbol("_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
}()

/// _AXUIElementCreateWithRemoteToken: reconstructs an AXUIElement from a raw
/// remote token. Used to resolve windows on other Spaces, which
/// kAXWindowsAttribute cannot see.
private let axCreateWithRemoteToken: (@convention(c) (CFData) -> Unmanaged<AXUIElement>?)? = {
    guard let sym = loadSymbol("_AXUIElementCreateWithRemoteToken") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CFData) -> Unmanaged<AXUIElement>?).self)
}()

enum RemoteToken {
    static var isAvailable: Bool { axCreateWithRemoteToken != nil }

    /// Brute-force AXUIElements for specific CGWindowIDs of one app
    /// (AltTab's windowsByBruteForce). Token layout: pid | 0 | 0x636f636f |
    /// candidate element ID. Only call for apps known to be responsive;
    /// the wall-clock budget bounds the damage if the app hangs mid-scan
    /// (each probe is a Mach round trip subject to the global AX timeout).
    static func resolveElements(pid: pid_t, targetWindowIDs: Set<CGWindowID>, budget: TimeInterval = 3) -> [CGWindowID: AXUIElement] {
        guard let create = axCreateWithRemoteToken, !targetWindowIDs.isEmpty else { return [:] }
        let deadline = Date().addingTimeInterval(budget)
        var remaining = targetWindowIDs
        var found: [CGWindowID: AXUIElement] = [:]
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { buffer in
            buffer.storeBytes(of: Int32(pid), toByteOffset: 0, as: Int32.self)
            buffer.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            buffer.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)
        }
        for candidate in UInt64(0)..<1500 {
            if Date() > deadline { break }
            token.withUnsafeMutableBytes { buffer in
                buffer.storeBytes(of: candidate, toByteOffset: 12, as: UInt64.self)
            }
            guard let element = create(token as CFData)?.takeRetainedValue(),
                  let windowID = element.cgWindowID,
                  remaining.contains(windowID) else { continue }
            // _AXUIElementGetWindow answers for ANY element inside the
            // window (buttons, fields…), and the window element's own ID may
            // sit far outside the scan range (Qt apps). Climb the parent
            // chain from whatever we hit up to the containing window.
            var candidateElement = element
            var hops = 0
            while candidateElement.string(kAXRoleAttribute) != kAXWindowRole, hops < 20 {
                guard let parent = candidateElement.element(kAXParentAttribute) else { break }
                candidateElement = parent
                hops += 1
            }
            guard candidateElement.string(kAXRoleAttribute) == kAXWindowRole,
                  candidateElement.cgWindowID == windowID else { continue }
            found[windowID] = candidateElement
            remaining.remove(windowID)
            if remaining.isEmpty { break }
        }
        return found
    }
}

// MARK: - SkyLight focus fallback

/// On macOS 14+ NSRunningApplication.activate is cooperative and can be
/// refused when called from a background LSUIElement app (the
/// ignoringOtherApps flag is a no-op there). This is the deterministic
/// fallback AltTab/yabai use to focus a specific window, including across
/// Spaces and fullscreen. Only invoked when the public path verifiably
/// failed; degrades to a no-op if the SPIs disappear.
private let slpsSetFrontProcess: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError)? = {
    let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    guard let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError).self)
}()

private let slpsPostEventRecordTo: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError)? = {
    let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    guard let sym = dlsym(handle, "SLPSPostEventRecordTo") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError).self)
}()

/// GetProcessForPID is marked unavailable in Swift (deprecated pre-10.9) but
/// still present and functional; PSNs remain required by the SLPS calls.
private let getProcessForPID: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus)? = {
    guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "GetProcessForPID") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self)
}()

enum SkyLight {
    private static let kCPSUserGenerated: UInt32 = 0x200

    static var isAvailable: Bool {
        slpsSetFrontProcess != nil && slpsPostEventRecordTo != nil && getProcessForPID != nil
    }

    /// Front the process for this specific window, then synthesize the
    /// "make key window" event pair (the Chromium technique).
    static func focusWindow(pid: pid_t, windowID: CGWindowID) {
        guard let setFront = slpsSetFrontProcess,
              let postEvent = slpsPostEventRecordTo,
              let getPSN = getProcessForPID else { return }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return }
        _ = setFront(&psn, windowID, kCPSUserGenerated)
        for eventKind: UInt8 in [0x01, 0x02] { // key-window down, then up
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x08] = eventKind
            bytes[0x3a] = 0x10
            var wid = windowID
            withUnsafeBytes(of: &wid) { widBytes in
                for (offset, byte) in widBytes.enumerated() {
                    bytes[0x3c + offset] = byte
                }
            }
            _ = postEvent(&psn, &bytes)
        }
    }
}

// MARK: - AXUIElement conveniences

extension AXUIElement {
    static func application(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    func rawValue(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? {
        rawValue(attribute) as? String
    }

    func bool(_ attribute: String) -> Bool? {
        rawValue(attribute) as? Bool
    }

    func elements(_ attribute: String) -> [AXUIElement]? {
        guard let value = rawValue(attribute), CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        return (value as! [AnyObject]).compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return (item as! AXUIElement)
        }
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = rawValue(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// One Mach round trip for several attributes; nil when the app could not
    /// be queried at all (timeout / dead process).
    func multiValues(_ attributes: [String]) -> [CFTypeRef?]? {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            self, attributes as CFArray, AXCopyMultipleAttributeOptions(), &values
        )
        guard error == .success, let values = values as? [AnyObject], values.count == attributes.count else { return nil }
        return values.map { item in
            // Missing attributes come back as AXValue error placeholders.
            if CFGetTypeID(item) == AXValueGetTypeID(),
               AXValueGetType(item as! AXValue) == .axError {
                return nil
            }
            return item as CFTypeRef
        }
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    var cgWindowID: CGWindowID? {
        guard let axGetWindow else { return nil }
        var id: CGWindowID = 0
        guard axGetWindow(self, &id) == .success, id != 0 else { return nil }
        return id
    }
}
