import Foundation
import Combine
import Darwin

public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var isRunning: Bool = false
    @Published public var connectedClient: String? = nil
    @Published public var localIP: String = "127.0.0.1"
    @Published public var localIPs: [String] = []
    @Published public var macAddress: String = "00:00:00:00:00:00"
    @Published public var isAccessibilityGranted: Bool = false

    @Published public var isNaturalScroll: Bool {
        didSet {
            InputSimulator.shared.isNaturalScroll = isNaturalScroll
        }
    }

    @Published public var launchAtLogin: Bool {
        didSet {
            SystemController.shared.setLaunchAtLogin(launchAtLogin)
        }
    }

    private init() {
        self.isNaturalScroll = InputSimulator.shared.isNaturalScroll
        self.launchAtLogin = SystemController.shared.isLaunchAtLoginEnabled
        refreshLocalIP()
        refreshMacAddress()
        checkPermissions()
    }

    public func checkPermissions() {
        isAccessibilityGranted = AccessibilityManager.isTrusted
    }

    public func refreshMacAddress() {
        self.macAddress = SystemController.shared.getPrimaryMacAddress() ?? "00:00:00:00:00:00"
    }

    public func refreshLocalIP() {
        var wiredIPs: [String] = []
        var wifiIPs: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            self.localIP = "127.0.0.1"
            self.localIPs = []
            return
        }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.starts(with: "en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    let foundIP = String(cString: hostname)
                    if !foundIP.isEmpty && foundIP != "127.0.0.1" && !foundIP.hasPrefix("169.254.") && !foundIP.hasPrefix("198.18.") {
                        if name == "en0" {
                            if !wifiIPs.contains(foundIP) {
                                wifiIPs.append(foundIP)
                            }
                        } else {
                            // en1..en9 (e.g. en3 AX88772A Wired Ethernet) has 0ms 802.11 Beacon sleep!
                            if !wiredIPs.contains(foundIP) {
                                wiredIPs.append(foundIP)
                            }
                        }
                    }
                }
            }
        }

        // Prioritize Wired Ethernet (en3) first to avoid secondary en0 102.4ms 802.11 PS-Poll sleep,
        // while keeping all LAN IPs in localIPs for multi-path delivery.
        let combined = wiredIPs + wifiIPs
        self.localIPs = combined
        self.localIP = combined.first ?? "127.0.0.1"
    }
}
