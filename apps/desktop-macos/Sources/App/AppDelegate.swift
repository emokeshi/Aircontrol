import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        AppState.shared.checkPermissions()
        AppState.shared.refreshLocalIP()
        AppState.shared.refreshMacAddress()

        setupStatusItem()
        startServices()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "AirControl")
        }
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        rebuildMenu()
    }

    public func menuWillOpen(_ menu: NSMenu) {
        AppState.shared.checkPermissions()
        AppState.shared.refreshLocalIP()
        AppState.shared.refreshMacAddress()
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()
        let state = AppState.shared

        // 1. Connection Status
        let statusTitle: String
        if let client = state.connectedClient, !client.isEmpty {
            statusTitle = "已连接：\(client)"
        } else {
            statusTitle = "等待手机连接"
        }
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusMenu.addItem(statusItem)

        // 2. Accessibility Warning (Only shown if permission is missing)
        if !state.isAccessibilityGranted {
            let permItem = NSMenuItem(
                title: "开启辅助功能权限…",
                action: #selector(openAccessibility),
                keyEquivalent: ""
            )
            permItem.target = self
            statusMenu.addItem(permItem)
        }

        statusMenu.addItem(.separator())

        // 3. Toggles
        let scrollItem = NSMenuItem(
            title: "自然滚动",
            action: #selector(toggleNaturalScroll),
            keyEquivalent: ""
        )
        scrollItem.target = self
        scrollItem.state = state.isNaturalScroll ? .on : .off
        statusMenu.addItem(scrollItem)

        let loginItem = NSMenuItem(
            title: "登录时打开",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = state.launchAtLogin ? .on : .off
        statusMenu.addItem(loginItem)

        statusMenu.addItem(.separator())

        // 4. IP & MAC Info (Click to copy)
        let ipItem = NSMenuItem(
            title: "IP 地址：\(state.localIP)",
            action: #selector(copyIPAddress),
            keyEquivalent: ""
        )
        ipItem.target = self
        statusMenu.addItem(ipItem)

        let macItem = NSMenuItem(
            title: "物理地址：\(state.macAddress)",
            action: #selector(copyMacAddress),
            keyEquivalent: ""
        )
        macItem.target = self
        statusMenu.addItem(macItem)

        statusMenu.addItem(.separator())

        // 5. Quit
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    @objc private func openAccessibility() {
        AccessibilityManager.openAccessibilitySettings()
        AccessibilityManager.requestAccess()
    }

    @objc private func toggleNaturalScroll() {
        AppState.shared.isNaturalScroll.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        AppState.shared.launchAtLogin.toggle()
    }

    @objc private func copyIPAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppState.shared.localIP, forType: .string)
    }

    @objc private func copyMacAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppState.shared.macAddress, forType: .string)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func startServices() {
        // Pure LAN TCP/UDP + Bonjour only (do NOT start MultipeerServer so awdl0 never hops off the 5GHz Wi-Fi channel!)
        SocketServer.shared.start(tcpPort: 8921, udpPort: 8920)
        AppState.shared.isRunning = true
    }
}
