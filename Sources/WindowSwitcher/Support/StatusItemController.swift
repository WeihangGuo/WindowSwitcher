import AppKit

/// Minimal menu-bar presence: the app has no Dock icon, so this is how the
/// user reaches Settings, onboarding, and Quit.
final class StatusItemController: NSObject, NSMenuDelegate {
    var onOpenSwitcher: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onGrantAccess: (() -> Void)?

    private let statusItem: NSStatusItem
    private let grantItem: NSMenuItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        grantItem = NSMenuItem(title: "Grant Accessibility Access…", action: nil, keyEquivalent: "")
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle",
            accessibilityDescription: "WindowSwitcher"
        )

        let menu = NSMenu()
        menu.delegate = self

        let openItem = NSMenuItem(title: "Open Switcher", action: #selector(openSwitcher), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        grantItem.action = #selector(grantAccess)
        grantItem.target = self
        menu.addItem(grantItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WindowSwitcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        grantItem.isHidden = AX.isTrusted
    }

    @objc private func openSwitcher() {
        onOpenSwitcher?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func grantAccess() {
        onGrantAccess?()
    }
}
