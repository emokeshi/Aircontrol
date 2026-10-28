import Foundation
import Darwin

public enum WoLError: LocalizedError {
    case invalidMacAddress
    case socketCreationFailed(Int32)
    case sendFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidMacAddress:
            return "无效的网卡物理 MAC 地址（需形如 AA:BB:CC:DD:EE:FF）"
        case .socketCreationFailed(let code):
            return "创建 UDP Socket 失败 (errno: \(code))"
        case .sendFailed(let code):
            return "请确认已连接局域网 Wi-Fi (errno: \(code))"
        }
    }
}

/// Industrial Wake-on-LAN (WoL) Magic Packet Generator & Broadcaster
/// Binds directly to physical Wi-Fi (`en0` via `IP_BOUND_IF`) to bypass SideStore/VPN `utun` interfaces
/// and dispatches to Subnet Broadcast (e.g. 192.168.0.255), Target Unicast IPs, and 255.255.255.255.
public final class WakeOnLAN: @unchecked Sendable {
    public static let shared = WakeOnLAN()

    private init() {}

    /// Parses a string representation of a MAC address (e.g. "AA:BB:CC:DD:EE:FF", "aa-bb-cc-dd-ee-ff", or "AABBCCDDEEFF")
    public static func parseMacAddress(_ macString: String) -> [UInt8]? {
        let clean = macString
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard clean.count == 12 else { return nil }

        var bytes = [UInt8]()
        var index = clean.startIndex
        for _ in 0..<6 {
            let nextIndex = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }

        // Reject all-zero placeholder MAC
        if bytes.allSatisfy({ $0 == 0 }) {
            return nil
        }

        return bytes
    }

    /// Creates the standard 102-byte Magic Packet: 6 bytes of 0xFF followed by 16 repetitions of target MAC
    public static func createMagicPacket(macBytes: [UInt8]) -> Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }
        return packet
    }

    /// Discovers `en0` subnet directed broadcast IP (e.g. 192.168.0.255)
    private static func discoverWifiBroadcastAddresses() -> [String] {
        var targets: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return ["255.255.255.255"]
        }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }

            let sinAddr = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if let maskPtr = interface.ifa_netmask {
                let sinMask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let broadcast = (sinAddr & sinMask) | (~sinMask)
                var bcastIn = in_addr(s_addr: broadcast)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &bcastIn, &buf, socklen_t(buf.count)) != nil {
                    let ip = String(cString: buf)
                    if !ip.isEmpty && !targets.contains(ip) {
                        targets.append(ip)
                    }
                }
            }
        }

        if !targets.contains("255.255.255.255") {
            targets.append("255.255.255.255")
        }
        return targets
    }

    /// Sends WoL magic packets bound to physical Wi-Fi (`en0`) across subnet broadcast + unicast host IPs
    public static func sendMagicPackets(mac: String, targetIPs: [String] = []) throws {
        guard let macBytes = parseMacAddress(mac) else {
            throw WoLError.invalidMacAddress
        }

        let magicPacket = createMagicPacket(macBytes: macBytes)

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw WoLError.socketCreationFailed(errno)
        }
        defer { close(fd) }

        // Enable SO_BROADCAST and SO_NOSIGPIPE
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        // Bind directly to en0 (Wi-Fi) so SideStore/VPN utun5 never hijacks or blocks the broadcast packet!
        var en0Index = if_nametoindex("en0")
        if en0Index > 0 {
            _ = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &en0Index, socklen_t(MemoryLayout<UInt32>.size))
        }

        var allDestinations = discoverWifiBroadcastAddresses()
        for ip in targetIPs where !ip.isEmpty && !allDestinations.contains(ip) {
            allDestinations.insert(ip, at: 0)
        }

        let ports: [UInt16] = [9, 7, 8920]
        var successCount = 0
        var lastErrno: Int32 = 0

        for destIP in allDestinations {
            let inAddr = inet_addr(destIP)
            guard inAddr != INADDR_NONE || destIP == "255.255.255.255" else { continue }

            for port in ports {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(port).bigEndian
                addr.sin_addr.s_addr = inAddr

                let sent = magicPacket.withUnsafeBytes { rawPtr in
                    withUnsafePointer(to: &addr) { addrPtr in
                        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                            sendto(fd, rawPtr.baseAddress, magicPacket.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if sent == magicPacket.count {
                    successCount += 1
                } else {
                    lastErrno = errno
                }
            }
        }

        if successCount == 0 {
            throw WoLError.sendFailed(lastErrno)
        }
    }

    /// Asynchronously wakes the target computer with a 3-burst transmission over subnet broadcast & target IPs
    public static func wake(mac: String, targetIPs: [String] = [], completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard parseMacAddress(mac) != nil else {
            completion?(.failure(WoLError.invalidMacAddress))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var anySuccess = false
            var lastError: Error? = nil

            for _ in 0..<3 {
                do {
                    try sendMagicPackets(mac: mac, targetIPs: targetIPs)
                    anySuccess = true
                } catch {
                    lastError = error
                }
                usleep(20_000)
            }

            DispatchQueue.main.async {
                if anySuccess {
                    completion?(.success(()))
                } else if let err = lastError {
                    completion?(.failure(err))
                } else {
                    completion?(.success(()))
                }
            }
        }
    }
}
