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
        var en0IP: String? = nil
        var allLanIPs: [String] = []
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
                if name.starts(with: "en") || name.starts(with: "bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    let foundIP = String(cString: hostname)
                    if !foundIP.isEmpty && foundIP != "127.0.0.1" && !foundIP.hasPrefix("169.254.") {
                        if name == "en0" {
                            en0IP = foundIP
                        }
                        if !allLanIPs.contains(foundIP) {
                            allLanIPs.append(foundIP)
                        }
                    }
                }
            }
        }

        if let primary = en0IP {
            // Put en0 (Wi-Fi) first
            allLanIPs.removeAll(where: { $0 == primary })
            allLanIPs.insert(primary, at: 0)
            self.localIP = primary
        } else if let first = allLanIPs.first {
            self.localIP = first
        } else {
            self.localIP = "127.0.0.1"
        }
        self.localIPs = allLanIPs
    }
}
