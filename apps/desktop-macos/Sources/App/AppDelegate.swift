import AppKit
import SwiftUI

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupPopover()
        setupStatusItem()
        startServices()

        AppState.shared.checkPermissions()
        AppState.shared.refreshLocalIP()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "AirControl")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 350)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        self.popover = popover
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        AppState.shared.checkPermissions()
        AppState.shared.refreshLocalIP()

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func startServices() {
        // Start Apple Native Multipeer Connectivity Server (AWDL + Wi-Fi Peer-to-Peer)
        MultipeerServer.shared.start()

        // Start High-Speed Local Wi-Fi Socket Server (UDP 8920 + TCP 8921)
        SocketServer.shared.start(tcpPort: 8921, udpPort: 8920)

        AppState.shared.isRunning = true
    }
}
